defmodule Meridian.AccessRequests.AccessRequest do
  @moduledoc """
  Someone asking to be added to Meridian: an email, and a name if they gave one. The operator
  accepts (which creates the user and deletes the request), snoozes, or rejects it.

  There is one request per email: asking again bumps `requested_at` and `times_requested`.
  """
  use Meridian.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @statuses ~w(pending snoozed rejected)

  schema "access_requests" do
    field :email, :string
    field :name, :string
    field :status, :string, default: "pending"
    field :status_changed_at, :utc_datetime_usec
    field :requested_at, :utc_datetime_usec
    field :times_requested, :integer, default: 1

    timestamps()
  end

  @doc false
  def changeset(request, attrs) do
    request
    |> cast(attrs, [:email, :name])
    |> update_change(:email, &String.trim/1)
    |> update_change(:name, &String.trim/1)
    |> validate_required([:email])
    |> validate_length(:email, max: 320)
    |> validate_length(:name, max: 200)
    |> validate_format(:email, ~r/^[^@\s]+@[^@\s]+$/, message: "must be a valid email address")
    |> unique_constraint(:email, name: :access_requests_email_index)
  end

  @doc false
  def status_changeset(request, status) when status in @statuses do
    change(request, status: status, status_changed_at: DateTime.utc_now())
  end
end
