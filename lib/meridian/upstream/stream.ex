defmodule Meridian.Upstream.Stream do
  @moduledoc """
  Runs a streaming chat completions request in its own process and forwards the response to
  the process that started it (the owner) as messages.

  `Req` blocks its caller until the upstream sends response headers, which can take minutes
  (a model being loaded, an overloaded upstream). Doing that here keeps the owner free to
  handle cancel requests and timers in the meantime.

  The owner receives `{:upstream, pid, message}`, where `message` is one of:

    * `{:items, items}` - response body items, as returned by `Req.parse_message/2`
      (`{:data, binary}`, ..., and `:done` once the body has ended)
    * `{:error_response, status, body}` - a non-200 response, with its whole body
    * `{:request_failed, reason}` - no response at all (`:not_configured` if there is no
      upstream)
    * `{:stream_failed, reason}` - the response body broke off

  The process exits normally after `:done` or a failure. It is linked to the owner, so it
  dies if the owner crashes; otherwise stop it with `cancel/1`.
  """

  alias Meridian.Upstream

  @doc "Starts streaming `body` (a chat completions request) to the calling process."
  @spec start_link(map()) :: {:ok, pid()}
  def start_link(body) when is_map(body) do
    owner = self()
    # A Task (rather than a bare spawn) records its callers, so ownership-based test sandboxes
    # (Req.Test) follow the request into it.
    Task.start_link(fn -> run(owner, body) end)
  end

  @doc "Stops the stream and closes the upstream connection. No more messages are sent."
  @spec cancel(pid()) :: :ok
  def cancel(pid) when is_pid(pid) do
    Process.unlink(pid)
    # The underlying HTTP request is linked to this process, so it is closed too.
    Process.exit(pid, :kill)
    :ok
  end

  defp run(owner, body) do
    case Upstream.chat_completions(body) do
      {:ok, %Req.Response{status: 200} = resp} ->
        relay(owner, resp)

      {:ok, %Req.Response{} = resp} ->
        notify(owner, {:error_response, resp.status, Enum.join(resp.body)})

      {:error, reason} ->
        notify(owner, {:request_failed, reason})
    end
  end

  defp relay(owner, resp) do
    receive do
      message ->
        case Req.parse_message(resp, message) do
          {:ok, items} ->
            notify(owner, {:items, items})
            if :done not in items, do: relay(owner, resp)

          {:error, reason} ->
            notify(owner, {:stream_failed, reason})

          :unknown ->
            relay(owner, resp)
        end
    end
  end

  defp notify(owner, message), do: send(owner, {:upstream, self(), message})
end
