defmodule Meridian.Repo.Migrations.RenamePersonasToAgents do
  use Ecto.Migration

  # Personas are called agents now, everywhere: tables, columns, constraints, the JSON stored
  # on API keys and background jobs, and (best effort) the names scripts use for them.
  def up do
    rename table(:personas), to: table(:agents)
    execute "ALTER INDEX personas_pkey RENAME TO agents_pkey"
    execute "ALTER INDEX personas_user_id_slug_index RENAME TO agents_user_id_slug_index"

    execute "ALTER INDEX personas_one_default_per_user_index RENAME TO agents_one_default_per_user_index"

    execute "ALTER TABLE agents RENAME CONSTRAINT personas_user_id_fkey TO agents_user_id_fkey"

    rename table(:threads), :persona_id, to: :agent_id
    execute "ALTER INDEX threads_persona_id_index RENAME TO threads_agent_id_index"

    execute "ALTER TABLE threads RENAME CONSTRAINT threads_persona_id_fkey TO threads_agent_id_fkey"

    rename table(:runs), :persona_snapshot, to: :agent_snapshot

    execute """
    UPDATE api_keys SET policy = (policy - 'default_persona' - 'allowed_personas')
      || jsonb_strip_nulls(jsonb_build_object(
           'default_agent', policy->'default_persona',
           'allowed_agents', policy->'allowed_personas'))
    WHERE policy ?| array['default_persona', 'allowed_personas']
    """

    execute """
    UPDATE oban_jobs SET args = jsonb_set(args #- '{ctx,persona}', '{ctx,agent}', args->'ctx'->'persona')
    WHERE args->'ctx' ? 'persona'
    """

    execute """
    UPDATE extensions SET source = regexp_replace(
      regexp_replace(source, '\\.persona\\M', '.agent', 'g'), '\\mpersona_id\\M', 'agent_id', 'g')
    """
  end

  def down do
    execute """
    UPDATE extensions SET source = regexp_replace(
      regexp_replace(source, '\\.agent\\M', '.persona', 'g'), '\\magent_id\\M', 'persona_id', 'g')
    """

    execute """
    UPDATE oban_jobs SET args = jsonb_set(args #- '{ctx,agent}', '{ctx,persona}', args->'ctx'->'agent')
    WHERE args->'ctx' ? 'agent'
    """

    execute """
    UPDATE api_keys SET policy = (policy - 'default_agent' - 'allowed_agents')
      || jsonb_strip_nulls(jsonb_build_object(
           'default_persona', policy->'default_agent',
           'allowed_personas', policy->'allowed_agents'))
    WHERE policy ?| array['default_agent', 'allowed_agents']
    """

    rename table(:runs), :agent_snapshot, to: :persona_snapshot

    execute "ALTER TABLE threads RENAME CONSTRAINT threads_agent_id_fkey TO threads_persona_id_fkey"
    execute "ALTER INDEX threads_agent_id_index RENAME TO threads_persona_id_index"
    rename table(:threads), :agent_id, to: :persona_id

    execute "ALTER TABLE agents RENAME CONSTRAINT agents_user_id_fkey TO personas_user_id_fkey"

    execute "ALTER INDEX agents_one_default_per_user_index RENAME TO personas_one_default_per_user_index"

    execute "ALTER INDEX agents_user_id_slug_index RENAME TO personas_user_id_slug_index"
    execute "ALTER INDEX agents_pkey RENAME TO personas_pkey"
    rename table(:agents), to: table(:personas)
  end
end
