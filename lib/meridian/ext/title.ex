defmodule Meridian.Ext.Title do
  @moduledoc """
  Names untitled threads. When a run completes on a thread without a title, a background job
  (`Meridian.Ext.Title.Worker`) asks the model for a short title. A title set in the meantime
  (e.g. by the user) is never overwritten.

  Settings: `model`, the upstream model to ask (default `nil`: the persona's model).
  """
  @behaviour Meridian.Extension

  alias Meridian.Ext.Title.Worker
  alias Meridian.Extension.API

  @impl true
  def name, do: "title"

  @impl true
  def description, do: "Names untitled threads after their first reply."

  @impl true
  def default_settings, do: %{"model" => nil}

  @impl true
  def validate_settings(%{"model" => model})
      when is_nil(model) or (is_binary(model) and model != ""),
      do: :ok

  def validate_settings(_settings),
    do: {:error, "model must be a model id, or null for the persona's model"}

  @impl true
  def run_end(%{status: :completed} = run, ctx) do
    case API.get_thread(run.thread_id) do
      %{title: nil} ->
        model = ctx.settings["model"] || ctx.persona.model
        {:ok, _job} = Oban.insert(Worker.new(%{thread_id: run.thread_id, model: model}))
        :ok

      _titled_or_gone ->
        :ok
    end
  end

  def run_end(_run, _ctx), do: :ok
end
