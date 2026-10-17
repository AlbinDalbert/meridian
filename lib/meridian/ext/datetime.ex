defmodule Meridian.Ext.Datetime do
  @moduledoc """
  Tells the model the current date and time, which it can't know otherwise, by adding a
  section to the run's system prompt.

  Settings: `timezone`, an IANA timezone name (default `"Etc/UTC"`).
  """
  @behaviour Meridian.Extension

  @impl true
  def name, do: "datetime"

  @impl true
  def description, do: "Adds the current date and time to the system prompt."

  @impl true
  def default_settings, do: %{"timezone" => "Etc/UTC"}

  @impl true
  def validate_settings(%{"timezone" => timezone}) when is_binary(timezone) do
    case DateTime.now(timezone) do
      {:ok, _now} -> :ok
      {:error, _reason} -> {:error, "unknown timezone #{inspect(timezone)}"}
    end
  end

  def validate_settings(_settings),
    do: {:error, ~s(timezone must be a timezone name, e.g. "Europe/Stockholm")}

  @impl true
  def before_run(config, ctx) do
    timezone = ctx.settings["timezone"]
    {:ok, now} = DateTime.now(timezone)
    {:cont, Map.update!(config, :system_prompt, &(&1 ++ [section(now, timezone)]))}
  end

  @doc false
  def section(%DateTime{} = now, timezone) do
    "The current date and time is " <>
      Calendar.strftime(now, "%A, %-d %B %Y, %H:%M") <>
      " (#{timezone}, UTC#{Calendar.strftime(now, "%z")})."
  end
end
