defmodule MeridianWeb.Api.MessageJSON do
  alias Meridian.Threads.Message
  alias MeridianWeb.Api.RunJSON

  def index(%{messages: messages, has_more: has_more}) do
    %{data: Enum.map(messages, &Message.to_map/1), has_more: has_more}
  end

  def create(%{message: message, run: run, current_api_key: api_key}) do
    %{data: %{message: Message.to_map(message), run: RunJSON.data(run, api_key)}}
  end
end
