defmodule Mithril.Schema.RequiredTables.Parser do
  @moduledoc false

  @create_table ~r/CREATE\s+TABLE\s+(?:IF\s+NOT\s+EXISTS\s+)?(?:public\.)?([a-zA-Z_][a-zA-Z0-9_]*)/i

  def tables_from_sql(sql) when is_binary(sql) do
    sql
    |> strip_comments()
    |> then(fn cleaned -> Regex.scan(@create_table, cleaned) end)
    |> Enum.map(fn [_, name] -> String.downcase(name) end)
  end

  def from_files(paths) when is_list(paths) do
    paths
    |> Enum.flat_map(fn path -> tables_from_sql(File.read!(path)) end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp strip_comments(sql) do
    sql
    |> String.replace(~r/\/\*.*?\*\//s, "")
    |> String.split("\n")
    |> Enum.map_join("\n", fn line -> line |> String.split("--", parts: 2) |> hd() end)
  end
end

defmodule Mithril.Schema.RequiredTables do
  @moduledoc false

  @tables Path.expand("../../../priv/repo/sql", __DIR__)
          |> Path.join("{direct,auth}/*.sql")
          |> Path.wildcard()
          |> Enum.sort()
          |> Mithril.Schema.RequiredTables.Parser.from_files()

  def tables, do: @tables

  defdelegate tables_from_sql(sql), to: Mithril.Schema.RequiredTables.Parser
  defdelegate from_files(paths), to: Mithril.Schema.RequiredTables.Parser
end
