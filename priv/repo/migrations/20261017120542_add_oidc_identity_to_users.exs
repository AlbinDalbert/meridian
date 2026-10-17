defmodule Meridian.Repo.Migrations.AddOidcIdentityToUsers do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :oidc_issuer, :text
      add :oidc_subject, :text
    end

    create unique_index(:users, [:oidc_issuer, :oidc_subject])
  end
end
