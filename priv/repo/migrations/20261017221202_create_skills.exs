defmodule Meridian.Repo.Migrations.CreateSkills do
  use Ecto.Migration

  def change do
    create table(:skills, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :text, null: false
      # What it's for: the model reads this to decide when to load the skill.
      add :description, :text, null: false
      # The instructions the model gets when it loads the skill.
      add :prompt, :text, null: false
      # Extensions the skill works best with (ids). Only a hint: nothing enforces them.
      add :recommended_extensions, {:array, :binary_id}, null: false, default: []
      # Who it belongs to; null for global skills, which every user can use.
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all)

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:skills, [:name],
             where: "user_id IS NULL",
             name: :skills_global_name_index
           )

    create unique_index(:skills, [:user_id, :name],
             where: "user_id IS NOT NULL",
             name: :skills_user_id_name_index
           )

    alter table(:personas) do
      # The skills the persona enables (ids).
      add :skills, {:array, :binary_id}, null: false, default: []
    end
  end
end
