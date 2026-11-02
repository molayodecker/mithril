#!/usr/bin/env python3
"""Insert source rows whose primary keys are missing on the target.

The target keeps every existing row. Conflicts are left as they are.
The source connection is read-only. Auth passwords, tokens, and secrets are
not copied. auth schema tables other than auth.users are skipped.
"""

from __future__ import annotations

import csv
import io
import os
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import time
from collections import defaultdict
from pathlib import Path

AUTH_USER_COLUMNS = {
    "id",
    "email",
    "phone",
    "created_at",
    "updated_at",
    "email_confirmed_at",
    "phone_confirmed_at",
    "last_sign_in_at",
    "banned_until",
    "deleted_at",
    "is_anonymous",
}

SECRET_MARKERS = ("password", "secret", "token", "recovery")
STAGE_SCHEMA_RE = re.compile(r"^merge_missing_[0-9]+_[0-9]+$")
SNAPSHOT_ID_RE = re.compile(r"^[0-9A-Fa-f-]+$")
TEXT_TYPE_PREFIXES = ("text", "character varying", "character")


def quote_ident(name: str) -> str:
    return '"' + name.replace('"', '""') + '"'


def quote_literal(value: str) -> str:
    return "'" + value.replace("'", "''") + "'"


def redact(text: str) -> str:
    return re.sub(r"postgres(?:ql)?://\S+", "postgresql://***", text)


def as_bool(value: str) -> bool:
    return value.strip().lower() in {"t", "true", "1", "yes"}


def type_family(data_type: str) -> str:
    return data_type.split("(", 1)[0].strip().lower()


def types_compatible(source_type: str, target_type: str) -> bool:
    if source_type == target_type:
        return True
    source_family = type_family(source_type)
    target_family = type_family(target_type)
    return source_family in TEXT_TYPE_PREFIXES and target_family in TEXT_TYPE_PREFIXES


def is_secret_column(schema: str, table: str, column: str) -> bool:
    if schema == "auth" and table == "users":
        return column not in AUTH_USER_COLUMNS
    lowered = column.lower()
    return any(marker in lowered for marker in SECRET_MARKERS)


def relation_key(schema: str, table: str) -> str:
    return f"{schema}.{table}"


class CommandError(RuntimeError):
    pass


def run_psql(
    url: str,
    sql: str,
    *,
    read_only: bool,
    tuples_only: bool = False,
    stdout_path: Path | None = None,
) -> str:
    env = os.environ.copy()
    options = env.get("PGOPTIONS", "")
    options = f"{options} -c statement_timeout=0".strip()
    if read_only:
        options = f"{options} -c default_transaction_read_only=on"
    else:
        options = f"{options} -c lock_timeout=60s"
    env["PGOPTIONS"] = options
    env["PGAPPNAME"] = "mithril_merge_missing"
    command = ["psql", url, "-X", "-q", "-v", "ON_ERROR_STOP=1"]
    if tuples_only:
        command.append("-At")
    # Role defaults can override PGOPTIONS. Set these in the session so a
    # long production copy is not canceled, while reads stay read-only.
    session = ["SET statement_timeout = 0;", "SET lock_timeout = '180s';"]
    if read_only:
        session.append("SET default_transaction_read_only = on;")
    sql = "\n".join(session) + "\n" + sql
    script_path: Path | None = None
    stdout_file = None
    if "\\copy" in sql:
        script_file = tempfile.NamedTemporaryFile("w", prefix="mithril-merge-", suffix=".sql", delete=False)
        script_file.write(sql)
        script_file.close()
        script_path = Path(script_file.name)
        os.chmod(script_path, 0o600)
        command.extend(["-f", str(script_path)])
    else:
        command.extend(["-c", sql])
    try:
        if stdout_path is not None:
            stdout_file = stdout_path.open("w")
            completed = subprocess.run(
                command,
                check=False,
                stdout=stdout_file,
                stderr=subprocess.PIPE,
                text=True,
                env=env,
            )
        else:
            completed = subprocess.run(
                command,
                check=False,
                capture_output=True,
                text=True,
                env=env,
            )
    finally:
        if stdout_file is not None:
            stdout_file.close()
        if script_path is not None:
            script_path.unlink(missing_ok=True)
    if completed.returncode != 0:
        message = redact((completed.stderr or completed.stdout or "").strip())
        raise CommandError(message or "psql failed")
    if stdout_path is not None:
        return ""
    return completed.stdout or ""


def copy_query(
    url: str,
    sql: str,
    *,
    read_only: bool,
    snapshot_id: str | None,
    stdout_path: Path | None = None,
) -> str:
    if snapshot_id is None:
        return run_psql(url, sql, read_only=read_only, stdout_path=stdout_path)
    if not SNAPSHOT_ID_RE.fullmatch(snapshot_id):
        raise CommandError("Unexpected snapshot id")
    statement = "\n".join(
        [
            "BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY;",
            f"SET TRANSACTION SNAPSHOT {quote_literal(snapshot_id)};",
            sql,
            "COMMIT;",
        ]
    )
    return run_psql(url, statement, read_only=read_only, stdout_path=stdout_path)


def query_csv(
    url: str,
    select_sql: str,
    *,
    read_only: bool,
    snapshot_id: str | None,
) -> list[dict[str, str]]:
    output = copy_query(
        url,
        f"COPY ({select_sql}) TO STDOUT WITH (FORMAT csv, HEADER true);",
        read_only=read_only,
        snapshot_id=snapshot_id,
    )
    return list(csv.DictReader(io.StringIO(output)))


def scalar(url: str, select_sql: str, *, read_only: bool, snapshot_id: str | None) -> str:
    if snapshot_id is None:
        output = run_psql(url, select_sql, read_only=read_only, tuples_only=True)
    else:
        if not SNAPSHOT_ID_RE.fullmatch(snapshot_id):
            raise CommandError("Unexpected snapshot id")
        output = run_psql(
            url,
            "\n".join(
                [
                    "BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY;",
                    f"SET TRANSACTION SNAPSHOT {quote_literal(snapshot_id)};",
                    select_sql,
                    "COMMIT;",
                ]
            ),
            read_only=read_only,
            tuples_only=True,
        )
    lines = [line.strip() for line in output.splitlines() if line.strip()]
    if not lines:
        return ""
    if len(lines) != 1:
        raise CommandError(f"Expected one value, got {lines!r}")
    return lines[0]


class SourceSnapshot:
    def __init__(self, source_url: str) -> None:
        self.source_url = source_url
        self.proc: subprocess.Popen[str] | None = None
        self.snapshot_id = ""
        self.error_path: Path | None = None

    def __enter__(self) -> str:
        self.error_path = Path(tempfile.mkstemp(prefix="mithril-merge-snapshot-", suffix=".err")[1])
        error_file = self.error_path.open("w")
        env = os.environ.copy()
        env["PGOPTIONS"] = (
            env.get("PGOPTIONS", "") + " -c default_transaction_read_only=on -c statement_timeout=0"
        ).strip()
        env["PGAPPNAME"] = "mithril_merge_missing_snapshot"
        self.proc = subprocess.Popen(
            ["psql", self.source_url, "-X", "-qAt", "-v", "ON_ERROR_STOP=1"],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=error_file,
            text=True,
            env=env,
        )
        error_file.close()
        assert self.proc.stdin is not None
        assert self.proc.stdout is not None
        self.proc.stdin.write(
            "BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY;\nSELECT pg_export_snapshot();\n"
        )
        self.proc.stdin.flush()
        self.snapshot_id = self.proc.stdout.readline().strip()
        if not SNAPSHOT_ID_RE.fullmatch(self.snapshot_id):
            detail = self.error_path.read_text() if self.error_path.exists() else ""
            raise CommandError(redact(detail) or "PostgreSQL did not export a snapshot id")
        return self.snapshot_id

    def __exit__(self, *_exc: object) -> None:
        if self.proc is not None and self.proc.poll() is None and self.proc.stdin is not None:
            try:
                self.proc.stdin.write("ROLLBACK;\n\\q\n")
                self.proc.stdin.flush()
            except OSError:
                pass
            try:
                self.proc.wait(timeout=10)
            except subprocess.TimeoutExpired:
                self.proc.kill()
        if self.error_path is not None:
            self.error_path.unlink(missing_ok=True)


def wait_for_release() -> None:
    ready = os.environ.get("MERGE_SNAPSHOT_READY_FILE", "")
    release = os.environ.get("MERGE_SNAPSHOT_RELEASE_FILE", "")
    if not ready:
        return
    Path(ready).write_text("ready\n")
    if not release:
        return
    while not Path(release).exists():
        time.sleep(0.05)


def load_columns(url: str, *, read_only: bool, snapshot_id: str | None) -> dict[str, list[dict[str, str]]]:
    rows = query_csv(
        url,
        """
        SELECT
          n.nspname AS schema_name,
          c.relname AS table_name,
          a.attname AS column_name,
          a.attnum::text AS attnum,
          a.attnotnull::text AS not_null,
          a.attidentity AS identity,
          a.attgenerated AS generated,
          pg_catalog.format_type(a.atttypid, a.atttypmod) AS data_type,
          (ad.adbin IS NOT NULL)::text AS has_default
        FROM pg_catalog.pg_class c
        JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
        JOIN pg_catalog.pg_attribute a ON a.attrelid = c.oid
        LEFT JOIN pg_catalog.pg_attrdef ad
          ON ad.adrelid = a.attrelid AND ad.adnum = a.attnum
        WHERE n.nspname IN ('public', 'auth')
          AND c.relkind IN ('r', 'p')
          AND NOT c.relispartition
          AND a.attnum > 0
          AND NOT a.attisdropped
        ORDER BY n.nspname, c.relname, a.attnum
        """,
        read_only=read_only,
        snapshot_id=snapshot_id,
    )
    grouped: dict[str, list[dict[str, str]]] = defaultdict(list)
    for row in rows:
        grouped[relation_key(row["schema_name"], row["table_name"])].append(row)
    return grouped


def load_primary_keys(url: str, *, read_only: bool, snapshot_id: str | None) -> dict[str, list[str]]:
    rows = query_csv(
        url,
        """
        SELECT
          n.nspname AS schema_name,
          c.relname AS table_name,
          a.attname AS column_name,
          k.ord::text AS key_order
        FROM pg_catalog.pg_constraint con
        JOIN pg_catalog.pg_class c ON c.oid = con.conrelid
        JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
        JOIN LATERAL unnest(con.conkey) WITH ORDINALITY AS k(attnum, ord) ON true
        JOIN pg_catalog.pg_attribute a ON a.attrelid = c.oid AND a.attnum = k.attnum
        WHERE con.contype = 'p'
          AND n.nspname IN ('public', 'auth')
          AND c.relkind IN ('r', 'p')
          AND NOT c.relispartition
        ORDER BY n.nspname, c.relname, k.ord
        """,
        read_only=read_only,
        snapshot_id=snapshot_id,
    )
    grouped: dict[str, list[str]] = defaultdict(list)
    for row in rows:
        grouped[relation_key(row["schema_name"], row["table_name"])].append(row["column_name"])
    return grouped


def load_foreign_keys(
    url: str,
    *,
    read_only: bool,
    snapshot_id: str | None,
) -> dict[str, list[dict[str, object]]]:
    rows = query_csv(
        url,
        """
        SELECT
          src_ns.nspname AS schema_name,
          src.relname AS table_name,
          con.conname AS constraint_name,
          src_a.attname AS column_name,
          tgt_ns.nspname AS referenced_schema,
          tgt.relname AS referenced_table,
          tgt_a.attname AS referenced_column,
          k.ord::text AS key_order
        FROM pg_catalog.pg_constraint con
        JOIN pg_catalog.pg_class src ON src.oid = con.conrelid
        JOIN pg_catalog.pg_namespace src_ns ON src_ns.oid = src.relnamespace
        JOIN pg_catalog.pg_class tgt ON tgt.oid = con.confrelid
        JOIN pg_catalog.pg_namespace tgt_ns ON tgt_ns.oid = tgt.relnamespace
        JOIN LATERAL unnest(con.conkey, con.confkey)
          WITH ORDINALITY AS k(src_att, tgt_att, ord) ON true
        JOIN pg_catalog.pg_attribute src_a
          ON src_a.attrelid = src.oid AND src_a.attnum = k.src_att
        JOIN pg_catalog.pg_attribute tgt_a
          ON tgt_a.attrelid = tgt.oid AND tgt_a.attnum = k.tgt_att
        WHERE con.contype = 'f'
          AND src_ns.nspname IN ('public', 'auth')
          AND src.relkind IN ('r', 'p')
          AND NOT src.relispartition
        ORDER BY src_ns.nspname, src.relname, con.conname, k.ord
        """,
        read_only=read_only,
        snapshot_id=snapshot_id,
    )
    constraints: dict[str, dict[str, dict[str, object]]] = defaultdict(dict)
    for row in rows:
        key = relation_key(row["schema_name"], row["table_name"])
        constraint = constraints[key].setdefault(
            row["constraint_name"],
            {
                "referenced_schema": row["referenced_schema"],
                "referenced_table": row["referenced_table"],
                "pairs": [],
            },
        )
        pairs = constraint["pairs"]
        assert isinstance(pairs, list)
        pairs.append((row["column_name"], row["referenced_column"]))
    return {key: list(value.values()) for key, value in constraints.items()}


def topo_sort(keys: list[str], foreign_keys: dict[str, list[dict[str, object]]]) -> list[str]:
    dependencies = {key: set() for key in keys}
    for key, constraints in foreign_keys.items():
        if key not in dependencies:
            continue
        for constraint in constraints:
            referenced = relation_key(
                str(constraint["referenced_schema"]),
                str(constraint["referenced_table"]),
            )
            if referenced in dependencies and referenced != key:
                dependencies[key].add(referenced)
    ready = sorted(key for key, parents in dependencies.items() if not parents)
    ordered: list[str] = []
    while ready:
        current = ready.pop(0)
        ordered.append(current)
        for key, parents in dependencies.items():
            if current in parents:
                parents.remove(current)
                if not parents and key not in ordered and key not in ready:
                    ready.append(key)
        ready.sort()
    leftover = sorted(set(keys) - set(ordered))
    return ordered + leftover


def qualified(schema: str, table: str) -> str:
    return f"{quote_ident(schema)}.{quote_ident(table)}"


def column_list(columns: list[str]) -> str:
    return ", ".join(quote_ident(column) for column in columns)


def pk_match(columns: list[str], left: str, right: str) -> str:
    return " AND ".join(
        f"{left}.{quote_ident(column)} IS NOT DISTINCT FROM {right}.{quote_ident(column)}"
        for column in columns
    )


def foreign_key_filters(constraints: list[dict[str, object]]) -> str:
    filters = []
    for constraint in constraints:
        pairs = constraint["pairs"]
        assert isinstance(pairs, list)
        null_checks = " OR ".join(f"s.{quote_ident(column)} IS NULL" for column, _referenced in pairs)
        exists_checks = " AND ".join(
            "parent.{referenced} IS NOT DISTINCT FROM s.{column}".format(
                referenced=quote_ident(referenced),
                column=quote_ident(column),
            )
            for column, referenced in pairs
        )
        referenced = qualified(
            str(constraint["referenced_schema"]),
            str(constraint["referenced_table"]),
        )
        filters.append(
            f"({null_checks} OR EXISTS (SELECT 1 FROM {referenced} AS parent WHERE {exists_checks}))"
        )
    if not filters:
        return ""
    return " AND " + " AND ".join(filters)


def count_source_rows(source_url: str, snapshot_id: str, schema: str, table: str) -> int:
    value = scalar(
        source_url,
        f"SELECT count(*)::bigint FROM {qualified(schema, table)};",
        read_only=True,
        snapshot_id=snapshot_id,
    )
    return int(value)


def export_source_csv(
    source_url: str,
    snapshot_id: str,
    schema: str,
    table: str,
    columns: list[str],
    destination: Path,
) -> None:
    select_list = column_list(columns)
    copy_query(
        source_url,
        (
            f"COPY (SELECT {select_list} FROM {qualified(schema, table)}) "
            "TO STDOUT WITH (FORMAT csv, HEADER true);"
        ),
        read_only=True,
        snapshot_id=snapshot_id,
        stdout_path=destination,
    )


def ensure_stage_schema(target_url: str, stage_schema: str) -> None:
    if not STAGE_SCHEMA_RE.fullmatch(stage_schema):
        raise CommandError("Refusing to create an unexpected staging schema")
    run_psql(
        target_url,
        f"DROP SCHEMA IF EXISTS {quote_ident(stage_schema)} CASCADE; "
        f"CREATE SCHEMA {quote_ident(stage_schema)};",
        read_only=False,
    )


def drop_stage_schema(target_url: str, stage_schema: str) -> None:
    if not STAGE_SCHEMA_RE.fullmatch(stage_schema):
        raise CommandError("Refusing to drop an unexpected staging schema")
    run_psql(
        target_url,
        f"DROP SCHEMA IF EXISTS {quote_ident(stage_schema)} CASCADE;",
        read_only=False,
    )


def temporary_row_policies_sql(*, drop_only: bool) -> str:
    # Forced row security still applies to the table owner. The copy role is
    # not covered by the app policies, so inserts fail. These two policies
    # exist only while missing rows are inserted, and only for current_user.
    create_policies = ""
    if not drop_only:
        create_policies = """
    EXECUTE format(
      'CREATE POLICY merge_missing_select ON %I.%I FOR SELECT TO %I USING (true)',
      rel.schema_name, rel.table_name, actor
    );
    EXECUTE format(
      'CREATE POLICY merge_missing_insert ON %I.%I FOR INSERT TO %I WITH CHECK (true)',
      rel.schema_name, rel.table_name, actor
    );"""
    return f"""
DO $$
DECLARE
  rel record;
  actor text := current_user;
BEGIN
  FOR rel IN
    SELECT n.nspname AS schema_name, c.relname AS table_name
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE c.relkind = 'r'
      AND c.relrowsecurity
      AND n.nspname IN ('public', 'auth')
  LOOP
    EXECUTE format('DROP POLICY IF EXISTS merge_missing_select ON %I.%I', rel.schema_name, rel.table_name);
    EXECUTE format('DROP POLICY IF EXISTS merge_missing_insert ON %I.%I', rel.schema_name, rel.table_name);
    {create_policies}
  END LOOP;
END $$;
"""


def install_temporary_row_policies(target_url: str) -> None:
    run_psql(target_url, temporary_row_policies_sql(drop_only=False), read_only=False)


def drop_temporary_row_policies(target_url: str) -> None:
    run_psql(target_url, temporary_row_policies_sql(drop_only=True), read_only=False)


def load_stage(
    target_url: str,
    stage_schema: str,
    stage_name: str,
    target_schema: str,
    target_table: str,
    columns: list[str],
    csv_path: Path,
) -> None:
    stage = qualified(stage_schema, stage_name)
    selected = column_list(columns)
    # WITH NO DATA keeps the target column types without copying rows.
    run_psql(
        target_url,
        f"CREATE UNLOGGED TABLE {stage} AS "
        f"SELECT {selected} FROM {qualified(target_schema, target_table)} WITH NO DATA;",
        read_only=False,
    )
    copy_sql = (
        f"\\copy {stage} ({selected}) FROM {quote_literal(str(csv_path))} "
        "WITH (FORMAT csv, HEADER true)"
    )
    run_psql(target_url, copy_sql, read_only=False)


def count_missing(target_url: str, stage_schema: str, stage_name: str, schema: str, table: str, pk: list[str]) -> int:
    value = scalar(
        target_url,
        "SELECT count(*)::bigint FROM "
        f"{qualified(stage_schema, stage_name)} AS s "
        f"WHERE NOT EXISTS (SELECT 1 FROM {qualified(schema, table)} AS t WHERE {pk_match(pk, 't', 's')});",
        read_only=False,
        snapshot_id=None,
    )
    return int(value)


def insert_missing_once(
    target_url: str,
    stage_schema: str,
    stage_name: str,
    schema: str,
    table: str,
    columns: list[str],
    pk: list[str],
    constraints: list[dict[str, object]],
    override_identity: bool,
) -> int:
    override = " OVERRIDING SYSTEM VALUE" if override_identity else ""
    selected = column_list(columns)
    statement = (
        "WITH inserted AS ("
        f"INSERT INTO {qualified(schema, table)} ({selected}){override} "
        f"SELECT {selected} FROM {qualified(stage_schema, stage_name)} AS s "
        f"WHERE NOT EXISTS (SELECT 1 FROM {qualified(schema, table)} AS t WHERE {pk_match(pk, 't', 's')})"
        f"{foreign_key_filters(constraints)} "
        "ON CONFLICT DO NOTHING RETURNING 1"
        ") SELECT count(*)::bigint FROM inserted;"
    )
    return int(scalar(target_url, statement, read_only=False, snapshot_id=None))


def raise_sequences(target_url: str, schema: str, table: str, columns: list[dict[str, str]]) -> None:
    for column in columns:
        if not column["identity"] and not as_bool(column["has_default"]):
            continue
        if type_family(column["data_type"]) not in {"smallint", "integer", "bigint"}:
            continue
        column_name = column["column_name"]
        sequence_name = scalar(
            target_url,
            f"SELECT coalesce(pg_get_serial_sequence({quote_literal(schema + '.' + table)}, {quote_literal(column_name)}), '');",
            read_only=False,
            snapshot_id=None,
        )
        if not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*(\.[A-Za-z_][A-Za-z0-9_]*)?", sequence_name):
            continue
        quoted_sequence = ".".join(quote_ident(part) for part in sequence_name.split("."))
        # Never move a sequence backward. The next value stays ahead of both
        # the current sequence and the highest copied key.
        run_psql(
            target_url,
            f"""
            DO $$
            DECLARE
              sequence_last bigint;
              sequence_called boolean;
              next_value bigint;
              max_value bigint;
            BEGIN
              SELECT last_value, is_called
              INTO sequence_last, sequence_called
              FROM {quoted_sequence};
              next_value := CASE WHEN sequence_called THEN sequence_last + 1 ELSE sequence_last END;
              SELECT MAX({quote_ident(column_name)}) INTO max_value FROM {qualified(schema, table)};
              IF max_value IS NOT NULL AND max_value + 1 > next_value THEN
                PERFORM setval({quote_literal(sequence_name)}::regclass, max_value, true);
              END IF;
            END
            $$;
            """,
            read_only=False,
        )


def bump_integer_sequences(target_url: str, schema: str, table: str, pk: list[str], source_columns: list[dict[str, str]]) -> None:
    by_name = {column["column_name"]: column for column in source_columns}
    selected = [by_name[name] for name in pk if name in by_name]
    raise_sequences(target_url, schema, table, selected)


def report_line(fields: list[str]) -> None:
    print("\t".join(field.replace("\t", " ") for field in fields), flush=True)


def main() -> int:
    source_url = os.environ.get("SOURCE_DATABASE_URL", "")
    target_url = os.environ.get("TARGET_DATABASE_URL", "")
    mode = os.environ.get("MERGE_MODE", "dry-run")
    stage_schema = os.environ.get("MERGE_STAGE_SCHEMA", "")
    if not source_url or not target_url:
        print("SOURCE_DATABASE_URL and TARGET_DATABASE_URL are required.", file=sys.stderr)
        return 1
    if source_url == target_url:
        print("SOURCE_DATABASE_URL and TARGET_DATABASE_URL are identical. Refusing merge.", file=sys.stderr)
        return 1
    if "supabase.co" in target_url or "supabase.com" in target_url:
        print("TARGET_DATABASE_URL looks like Supabase. Refusing to write to it.", file=sys.stderr)
        return 1
    if mode not in {"dry-run", "apply"}:
        print("MERGE_MODE must be dry-run or apply.", file=sys.stderr)
        return 1
    if mode == "apply" and os.environ.get("CONFIRM_MISSING_MERGE") != "YES":
        print("Refusing to write without CONFIRM_MISSING_MERGE=YES.", file=sys.stderr)
        return 1
    if mode == "apply" and not STAGE_SCHEMA_RE.fullmatch(stage_schema):
        print("Refusing to write without a private staging schema name.", file=sys.stderr)
        return 1

    signal.signal(signal.SIGTERM, lambda *_args: sys.exit(1))
    work_dir = Path(tempfile.mkdtemp(prefix="mithril-merge-missing-"))
    os.chmod(work_dir, 0o700)
    incomplete = False
    try:
        with SourceSnapshot(source_url) as snapshot_id:
            wait_for_release()
            source_columns = load_columns(source_url, read_only=True, snapshot_id=snapshot_id)
            target_columns = load_columns(target_url, read_only=True, snapshot_id=None)
            source_keys = load_primary_keys(source_url, read_only=True, snapshot_id=snapshot_id)
            target_keys = load_primary_keys(target_url, read_only=True, snapshot_id=None)
            target_foreign_keys = load_foreign_keys(target_url, read_only=True, snapshot_id=None)

            report_line(
                [
                    "schema.table",
                    "status",
                    "source_rows",
                    "missing",
                    "inserted",
                    "blocked",
                    "skipped_unique",
                    "detail",
                ]
            )

            plans: list[dict[str, object]] = []
            for key in sorted(set(source_columns) | set(target_columns)):
                schema, table = key.split(".", 1)
                if key not in source_columns:
                    report_line([key, "target_only_untouched", "0", "0", "0", "0", "0", ""])
                    continue
                if schema == "auth" and table != "users":
                    source_rows = count_source_rows(source_url, snapshot_id, schema, table)
                    report_line([key, "skipped_auth_secrets", str(source_rows), "0", "0", "0", "0", ""])
                    if source_rows > 0:
                        incomplete = True
                    continue
                if key not in target_columns:
                    source_rows = count_source_rows(source_url, snapshot_id, schema, table)
                    report_line([key, "skipped_missing_on_target", str(source_rows), "0", "0", "0", "0", ""])
                    if source_rows > 0:
                        incomplete = True
                    continue

                source_by_name = {column["column_name"]: column for column in source_columns[key]}
                target_by_name = {column["column_name"]: column for column in target_columns[key]}
                pk = target_keys.get(key, [])
                source_rows = count_source_rows(source_url, snapshot_id, schema, table)
                if not pk or source_keys.get(key) != pk:
                    report_line([key, "skipped_no_primary_key", str(source_rows), "0", "0", "0", "0", ""])
                    if source_rows > 0:
                        incomplete = True
                    continue

                insert_columns: list[str] = []
                pk_type_mismatch: list[str] = []
                for column in source_columns[key]:
                    name = column["column_name"]
                    target_column = target_by_name.get(name)
                    if target_column is None or is_secret_column(schema, table, name):
                        continue
                    if column["generated"] or target_column["generated"]:
                        continue
                    if not types_compatible(column["data_type"], target_column["data_type"]):
                        if name in pk:
                            pk_type_mismatch.append(name)
                        continue
                    insert_columns.append(name)

                if pk_type_mismatch:
                    report_line(
                        [key, "skipped_pk_type", str(source_rows), "0", "0", "0", "0", ",".join(pk_type_mismatch)]
                    )
                    if source_rows > 0:
                        incomplete = True
                    continue
                if any(column not in insert_columns for column in pk):
                    report_line([key, "skipped_pk_type", str(source_rows), "0", "0", "0", "0", "primary key"])
                    if source_rows > 0:
                        incomplete = True
                    continue

                missing_required = []
                for column in target_columns[key]:
                    name = column["column_name"]
                    if name in insert_columns or column["generated"] or column["identity"]:
                        continue
                    if as_bool(column["not_null"]) and not as_bool(column["has_default"]):
                        missing_required.append(name)
                if missing_required:
                    report_line(
                        [
                            key,
                            "skipped_required_column",
                            str(source_rows),
                            "0",
                            "0",
                            "0",
                            "0",
                            ",".join(missing_required),
                        ]
                    )
                    if source_rows > 0:
                        incomplete = True
                    continue

                constraints = target_foreign_keys.get(key, [])
                missing_fk = sorted(
                    {
                        column
                        for constraint in constraints
                        for column, _referenced in constraint["pairs"]  # type: ignore[misc]
                        if column not in insert_columns
                    }
                )
                if missing_fk:
                    report_line(
                        [key, "skipped_fk_column", str(source_rows), "0", "0", "0", "0", ",".join(missing_fk)]
                    )
                    if source_rows > 0:
                        incomplete = True
                    continue

                override_identity = any(
                    target_by_name[name]["identity"] for name in insert_columns if target_by_name[name]["identity"]
                )
                plans.append(
                    {
                        "key": key,
                        "schema": schema,
                        "table": table,
                        "columns": insert_columns,
                        "pk": pk,
                        "constraints": constraints,
                        "override_identity": override_identity,
                        "source_rows": source_rows,
                        "target_column_defs": target_columns[key],
                    }
                )

            if mode == "dry-run":
                missing_rows = 0
                for plan in plans:
                    key = str(plan["key"])
                    schema = str(plan["schema"])
                    table = str(plan["table"])
                    columns = list(plan["columns"])
                    pk = list(plan["pk"])
                    csv_path = work_dir / f"{schema}__{table}.csv"
                    export_source_csv(source_url, snapshot_id, schema, table, pk, csv_path)
                    # Count missing keys in a rolled-back session. No public row changes.
                    selected = column_list(pk)
                    count_sql = "\n".join(
                        [
                            "BEGIN;",
                            f"CREATE TEMP TABLE merge_keys AS SELECT {selected} FROM {qualified(schema, table)} WITH NO DATA;",
                            f"\\copy merge_keys ({selected}) FROM {quote_literal(str(csv_path))} WITH (FORMAT csv, HEADER true)",
                            "SELECT count(*)::bigint FROM merge_keys AS s",
                            f"WHERE NOT EXISTS (SELECT 1 FROM {qualified(schema, table)} AS t WHERE {pk_match(pk, 't', 's')});",
                            "ROLLBACK;",
                        ]
                    )
                    output = run_psql(target_url, count_sql, read_only=False, tuples_only=True)
                    missing = int(next(line.strip() for line in output.splitlines() if line.strip()))
                    report_line([key, "dry_run", str(plan["source_rows"]), str(missing), "0", "0", "0", ""])
                    missing_rows += missing
                print(
                    f"result=dry_run missing_rows={missing_rows} needs_review={'yes' if incomplete else 'no'}",
                    flush=True,
                )
                return 0

            ensure_stage_schema(target_url, stage_schema)
            for plan in plans:
                schema = str(plan["schema"])
                table = str(plan["table"])
                columns = list(plan["columns"])
                csv_path = work_dir / f"{schema}__{table}.csv"
                print(f"progress copying {schema}.{table}", flush=True)
                export_source_csv(source_url, snapshot_id, schema, table, columns, csv_path)
                load_stage(
                    target_url,
                    stage_schema,
                    f"{schema}__{table}",
                    schema,
                    table,
                    columns,
                    csv_path,
                )

            print("progress inserting missing rows", flush=True)
            install_temporary_row_policies(target_url)
            inserted_counts = {str(plan["key"]): 0 for plan in plans}
            ordered = topo_sort([str(plan["key"]) for plan in plans], target_foreign_keys)
            plans_by_key = {str(plan["key"]): plan for plan in plans}
            for _round in range(200):
                progress = False
                for key in ordered:
                    plan = plans_by_key[key]
                    inserted = insert_missing_once(
                        target_url,
                        stage_schema,
                        f"{plan['schema']}__{plan['table']}",
                        str(plan["schema"]),
                        str(plan["table"]),
                        list(plan["columns"]),
                        list(plan["pk"]),
                        list(plan["constraints"]),
                        bool(plan["override_identity"]),
                    )
                    if inserted:
                        inserted_counts[key] += inserted
                        progress = True
                if not progress:
                    break

            for plan in plans:
                key = str(plan["key"])
                schema = str(plan["schema"])
                table = str(plan["table"])
                pk = list(plan["pk"])
                missing_before = count_missing(
                    target_url,
                    stage_schema,
                    f"{schema}__{table}",
                    schema,
                    table,
                    pk,
                )
                # count_missing is after inserts, so it is the remainder.
                blocked_or_unique = missing_before
                inserted = inserted_counts[key]
                # Split the remainder: foreign-key filters still failing are blocked.
                constraints = list(plan["constraints"])
                if constraints and blocked_or_unique:
                    blocked = int(
                        scalar(
                            target_url,
                            "SELECT count(*)::bigint FROM "
                            f"{qualified(stage_schema, schema + '__' + table)} AS s "
                            f"WHERE NOT EXISTS (SELECT 1 FROM {qualified(schema, table)} AS t "
                            f"WHERE {pk_match(pk, 't', 's')}) AND NOT ("
                            + foreign_key_filters(constraints).removeprefix(" AND ")
                            + ");",
                            read_only=False,
                            snapshot_id=None,
                        )
                    )
                else:
                    blocked = 0 if not constraints else blocked_or_unique
                skipped_unique = blocked_or_unique - blocked
                if blocked or skipped_unique:
                    incomplete = True
                status = "inserted" if inserted else "unchanged"
                if blocked:
                    status = "blocked"
                elif skipped_unique:
                    status = "skipped_unique"
                report_line(
                    [
                        key,
                        status,
                        str(plan["source_rows"]),
                        str(inserted + blocked_or_unique),
                        str(inserted),
                        str(blocked),
                        str(skipped_unique),
                        "",
                    ]
                )
                if inserted:
                    bump_integer_sequences(
                        target_url,
                        schema,
                        table,
                        pk,
                        list(plan["target_column_defs"]),
                    )
        print(f"result=apply incomplete={'yes' if incomplete else 'no'}", flush=True)
        return 2 if incomplete else 0
    finally:
        shutil.rmtree(work_dir, ignore_errors=True)
        if mode == "apply" and STAGE_SCHEMA_RE.fullmatch(stage_schema):
            try:
                drop_temporary_row_policies(target_url)
            except CommandError:
                pass
            try:
                drop_stage_schema(target_url, stage_schema)
            except CommandError:
                pass


if __name__ == "__main__":
    try:
        sys.exit(main())
    except CommandError as exc:
        print(redact(str(exc)), file=sys.stderr)
        sys.exit(1)
