defmodule Meridian.Upstream.SSE do
  @moduledoc """
  Incremental parser for a server-sent events stream, as sent by streaming chat completions.

  Feed it chunks as they arrive; it returns the `data` of every event completed so far and
  keeps the incomplete rest for the next chunk. Only `data` fields are kept: OpenAI-compatible
  upstreams don't use event names or ids.
  """
  defstruct buffer: ""

  @type t :: %__MODULE__{buffer: binary()}

  def new, do: %__MODULE__{}

  @doc "Parses `chunk`, returning the data of each completed event."
  @spec parse(t(), binary()) :: {[String.t()], t()}
  def parse(%__MODULE__{buffer: buffer} = parser, chunk) do
    [rest | complete] =
      (buffer <> chunk)
      |> String.replace("\r\n", "\n")
      |> String.split("\n\n")
      |> Enum.reverse()

    data =
      complete
      |> Enum.reverse()
      |> Enum.flat_map(fn event ->
        case event_data(event) do
          nil -> []
          data -> [data]
        end
      end)

    {data, %{parser | buffer: rest}}
  end

  defp event_data(event) do
    lines =
      for line <- String.split(event, "\n"), String.starts_with?(line, "data:") do
        line |> String.replace_prefix("data:", "") |> String.replace_prefix(" ", "")
      end

    if lines == [], do: nil, else: Enum.join(lines, "\n")
  end
end
