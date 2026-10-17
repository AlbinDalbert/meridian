defmodule Meridian.Extension.API do
  @moduledoc """
  The part of the core extensions may use. Extensions call these functions, never the internal
  contexts (`Meridian.Threads`, `Meridian.Upstream`, ...), so the core can change underneath
  them. If an extension needs something that isn't here, add it here.

  Extensions may also use libraries directly, e.g. `Oban` for background jobs (on the shared
  `extensions` queue).
  """

  alias Meridian.{Repo, Threads, Upstream}
  alias Meridian.Threads.{Message, Thread}

  ## Threads

  @doc "Gets a thread, or nil."
  @spec get_thread(Ecto.UUID.t()) :: Thread.t() | nil
  def get_thread(id), do: Repo.get(Thread, id)

  @doc "All of a thread's messages, oldest first."
  @spec list_messages(Ecto.UUID.t()) :: [Message.t()]
  def list_messages(thread_id), do: Threads.list_all_messages(%Thread{id: thread_id})

  @doc "The text of a message's text parts (no reasoning)."
  @spec message_text(Message.t()) :: String.t()
  def message_text(%Message{} = message), do: Message.text(message)

  @doc """
  Sets a thread's title. With `only_if_untitled: true`, a title that is already set is left
  alone (`{:error, :titled}`). Titles are trimmed and cut to 500 characters.
  """
  @spec set_thread_title(Ecto.UUID.t(), String.t(), keyword()) ::
          :ok | {:error, :titled | :not_found}
  def set_thread_title(thread_id, title, opts \\ []) when is_binary(title) do
    Threads.set_title(thread_id, title |> String.trim() |> String.slice(0, 500), opts)
  end

  ## Models

  @doc """
  Sends a non-streaming chat completions request (`model` and `messages` required) to the
  upstream and returns the decoded response.
  """
  @spec complete(map()) :: {:ok, map()} | {:error, term()}
  def complete(body), do: Upstream.complete(body)

  @doc "The text of the first choice of a `complete/1` response."
  @spec completion_text(map()) :: {:ok, String.t()} | :error
  def completion_text(%{"choices" => [%{"message" => %{"content" => text}} | _]})
      when is_binary(text),
      do: {:ok, text}

  def completion_text(_response), do: :error
end
