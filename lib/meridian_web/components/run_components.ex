defmodule MeridianWeb.RunComponents do
  @moduledoc """
  Components for showing runs in the admin console: only what happened and how much it cost,
  never what was said (no thread titles, agents, or messages).
  """
  use Phoenix.Component

  use Phoenix.VerifiedRoutes,
    endpoint: MeridianWeb.Endpoint,
    router: MeridianWeb.Router,
    statics: MeridianWeb.static_paths()

  import MeridianWeb.CoreComponents

  @doc "A run's status as a badge."
  attr :status, :atom, required: true

  def run_status(assigns) do
    ~H"""
    <span class={"badge status-#{@status}"}>{@status}</span>
    """
  end

  @doc "A table of runs. With `show_user`, the runs' threads and their users must be preloaded."
  attr :id, :string, required: true
  attr :runs, :list, required: true
  attr :show_user, :boolean, default: false

  def run_table(assigns) do
    ~H"""
    <.table id={@id} rows={@runs} empty="No runs yet.">
      <:col :let={run} label="Run">
        <.link navigate={~p"/admin/runs/#{run}"}><code>{String.slice(run.id, -8, 8)}</code></.link>
      </:col>
      <:col :let={run} :if={@show_user} label="User">
        <.link navigate={~p"/admin/users/#{run.thread.user}"}>{run.thread.user.name}</.link>
      </:col>
      <:col :let={run} label="Status"><.run_status status={run.status} /></:col>
      <:col :let={run} label="Model"><code>{run.model}</code></:col>
      <:col :let={run} label="Created">{format_time(run.inserted_at)}</:col>
      <:col :let={run} label="Usage">{format_usage(run.usage)}</:col>
    </.table>
    """
  end

  @doc "Formats a run's token usage."
  def format_usage(%{"prompt_tokens" => prompt, "completion_tokens" => completion}),
    do: "#{prompt} in / #{completion} out"

  def format_usage(_usage), do: "—"
end
