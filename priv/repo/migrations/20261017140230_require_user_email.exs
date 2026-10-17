defmodule Meridian.Repo.Migrations.RequireUserEmail do
  use Ecto.Migration

  def up do
    # Fail with an actionable message rather than Postgres' "contains null values". Emails can't
    # be made up here; give each listed user one in the admin console (on the previous release)
    # and migrate again.
    execute """
    DO $$
    DECLARE
      missing text;
    BEGIN
      SELECT string_agg(name || ' (' || id || ')', ', ') INTO missing
      FROM users WHERE email IS NULL OR btrim(email) = '';

      IF missing IS NOT NULL THEN
        RAISE EXCEPTION 'Every user now needs an email. Users without one: %', missing;
      END IF;
    END $$;
    """

    alter table(:users) do
      modify :email, :text, null: false
    end
  end

  def down do
    alter table(:users) do
      modify :email, :text, null: true
    end
  end
end
