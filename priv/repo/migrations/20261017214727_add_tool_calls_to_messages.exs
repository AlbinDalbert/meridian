defmodule Meridian.Repo.Migrations.AddToolCallsToMessages do
  use Ecto.Migration

  def change do
    alter table(:messages) do
      # The tool calls an assistant message asked for, in the OpenAI format.
      add :tool_calls, {:array, :map}
      # For tool messages: the call this is the result of.
      add :tool_call_id, :text
    end
  end
end
