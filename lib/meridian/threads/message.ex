defmodule Meridian.Threads.Message do
  @moduledoc """
  A message in a thread.

  `content` is a list of parts, as in the OpenAI API: `%{"type" => "text", "text" => ...}`,
  `%{"type" => "image_url", ...}`, and, for assistant messages, `%{"type" => "reasoning",
  "text" => ...}` (reasoning is kept for display but never sent back upstream). `metadata`
  holds annotations such as the assistant's `finish_reason`.
  """
  use Meridian.Schema

  import Ecto.Changeset

  @roles ~w(user assistant)

  schema "messages" do
    field :role, :string
    field :content, {:array, :map}, default: []
    field :metadata, :map, default: %{}
    field :usage, :map

    belongs_to :thread, Meridian.Threads.Thread
    belongs_to :run, Meridian.Runs.Run

    timestamps(updated_at: false)
  end

  @doc """
  Changeset for a message sent by a client. `content` may be a string (one text part) or a
  list of parts.
  """
  def user_changeset(message, attrs) do
    attrs = normalize_content(attrs)

    message
    |> cast(attrs, [:content])
    |> put_change(:role, "user")
    |> validate_change(:content, &validate_parts/2)
    |> validate_not_empty()
    |> validate_inclusion(:role, @roles)
  end

  @doc "The message as clients see it (API responses, `message.completed` events)."
  def to_map(%__MODULE__{} = message) do
    %{
      "id" => message.id,
      "thread_id" => message.thread_id,
      "run_id" => message.run_id,
      "role" => message.role,
      "content" => message.content,
      "metadata" => message.metadata,
      "usage" => message.usage,
      "inserted_at" => message.inserted_at
    }
  end

  @doc """
  The message in the OpenAI chat format, for sending upstream. Reasoning parts are dropped;
  text-only content is sent as a plain string, which every upstream accepts.
  """
  def to_upstream(%__MODULE__{role: role, content: parts}) do
    parts = Enum.reject(parts, &match?(%{"type" => "reasoning"}, &1))

    content =
      if Enum.all?(parts, &match?(%{"type" => "text"}, &1)),
        do: Enum.map_join(parts, & &1["text"]),
        else: parts

    %{"role" => role, "content" => content}
  end

  @doc "Text of all `text` parts, joined."
  def text(%__MODULE__{content: parts}), do: parts_text(parts, "text")

  @doc "Text of all `reasoning` parts, joined."
  def reasoning(%__MODULE__{content: parts}), do: parts_text(parts, "reasoning")

  defp parts_text(parts, type) do
    for %{"type" => ^type, "text" => text} <- parts, into: "", do: text
  end

  defp normalize_content(%{"content" => text} = attrs) when is_binary(text) do
    %{attrs | "content" => [%{"type" => "text", "text" => text}]}
  end

  defp normalize_content(%{content: text} = attrs) when is_binary(text) do
    %{attrs | content: [%{"type" => "text", "text" => text}]}
  end

  defp normalize_content(attrs), do: attrs

  # validate_required doesn't consider [] missing.
  defp validate_not_empty(changeset) do
    if get_field(changeset, :content) in [nil, []],
      do: add_error(changeset, :content, "can't be blank"),
      else: changeset
  end

  defp validate_parts(:content, parts) do
    if Enum.all?(parts, &valid_part?/1),
      do: [],
      else: [content: "must be a string or a list of text/image_url parts"]
  end

  defp valid_part?(%{"type" => "text", "text" => text}) when is_binary(text),
    do: String.trim(text) != ""

  defp valid_part?(%{"type" => "image_url", "image_url" => %{"url" => url}}) when is_binary(url),
    do: true

  defp valid_part?(_part), do: false
end
