ExUnit.start()

# The lightweight CI test database does not run all production migrations.
# Install the isolated WhatsApp chef tables so shared APPLY/CHEF routing tests
# exercise the real database lookup rather than failing on a missing relation.
Code.require_file("../priv/repo/migrations/20261021150000_create_whatsapp_chef_intakes.exs", __DIR__)

Ecto.Migrator.up(
  Mithril.Repo,
  20_261_021_150_000,
  Mithril.Repo.Migrations.CreateWhatsAppChefIntakes,
  log: false
)

Ecto.Adapters.SQL.Sandbox.mode(Mithril.Repo, :manual)
