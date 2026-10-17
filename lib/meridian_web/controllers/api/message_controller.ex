defmodule MeridianWeb.Api.MessageController do
  @moduledoc """
  `/api/threads/:thread_id/messages`: a thread's history, and sending a message (which starts a
  run and returns right away).
  """
  use MeridianWeb, :controller

  alias Meridian.Threads

  action_fallback MeridianWeb.Api.FallbackController

  def index(conn, %{"thread_id" => thread_id} = params) do
    with %{} = thread <- Threads.get_user_thread(conn.assigns.current_user, thread_id) do
      {messages, has_more} =
        Threads.list_messages(thread, before: params["before"], limit: params["limit"])

      render(conn, :index, messages: messages, has_more: has_more)
    end
  end

  def create(conn, %{"thread_id" => thread_id}) do
    %{current_user: user, current_policy: policy} = conn.assigns

    with %{} = thread <- Threads.get_user_thread(user, thread_id),
         {:ok, message, run} <- Threads.send_message(thread, policy, conn.body_params) do
      conn
      |> put_status(:accepted)
      |> render(:create, message: message, run: run)
    end
  end
end
