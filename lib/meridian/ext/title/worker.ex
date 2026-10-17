defmodule Meridian.Ext.Title.Worker do
  @moduledoc """
  Asks the model for a title for a thread, from its first exchange, and sets it unless the
  thread got a title in the meantime. One job per thread at a time.
  """
  use Oban.Worker,
    queue: :extensions,
    max_attempts: 3,
    unique: [keys: [:thread_id], states: :incomplete, period: :infinity]

  alias Meridian.Extension.API

  @prompt """
  You name conversations. Reply with a short title (at most six words) for the conversation \
  below, in the language of the conversation. Reply with the title only: no quotes, no \
  trailing punctuation.\
  """

  # Characters of each message the model gets to see.
  @excerpt_length 2000

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"thread_id" => thread_id, "model" => model}}) do
    with %{title: nil} <- API.get_thread(thread_id),
         excerpt when excerpt != "" <- excerpt(API.list_messages(thread_id)) do
      request = %{
        "model" => model,
        "messages" => [
          %{"role" => "system", "content" => @prompt},
          %{"role" => "user", "content" => excerpt}
        ]
      }

      with {:ok, response} <- API.complete(request),
           {:ok, text} <- API.completion_text(response),
           title when title != "" <- clean(text) do
        _ = API.set_thread_title(thread_id, title, only_if_untitled: true)
        :ok
      else
        {:error, reason} -> {:error, reason}
        _no_title -> {:cancel, "the model gave no title"}
      end
    else
      # Titled meanwhile, deleted, or nothing to name it after.
      _ -> :ok
    end
  end

  # The first user message and the first reply, as a short transcript.
  defp excerpt(messages) do
    user = Enum.find(messages, &(&1.role == "user"))
    assistant = Enum.find(messages, &(&1.role == "assistant"))

    [{"User", user}, {"Assistant", assistant}]
    |> Enum.filter(fn {_label, message} -> message end)
    |> Enum.map(fn {label, message} ->
      "#{label}: #{message |> API.message_text() |> String.slice(0, @excerpt_length)}"
    end)
    |> Enum.join("\n\n")
  end

  @doc false
  # Models add quotes, markdown, a trailing period, or inline reasoning despite being asked
  # not to.
  def clean(text) do
    text
    |> String.replace(~r/<think>.*?<\/think>/s, "")
    |> String.split("\n", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.find("", &(&1 != ""))
    |> String.replace_prefix("Title:", "")
    |> String.trim()
    |> String.trim("\"")
    |> String.trim("*")
    |> String.trim_leading("#")
    |> String.trim()
    |> String.trim_trailing(".")
    |> String.slice(0, 100)
  end
end
