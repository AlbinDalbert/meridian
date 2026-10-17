defmodule Meridian.Personas.Persona do
  @moduledoc """
  A named bundle of system prompt, upstream model, and default params, presented to clients as
  the model `meridian/<slug>`.

  `extensions` maps the name of each extension the persona enables to its settings (see
  `Meridian.Extensions`).
  """
  use Meridian.Schema

  import Ecto.Changeset

  @model_prefix "meridian/"

  @type t :: %__MODULE__{}

  schema "personas" do
    field :slug, :string
    field :name, :string
    field :system_prompt, :string, default: ""
    field :model, :string
    field :params, :map, default: %{}
    field :extensions, :map, default: %{}
    field :is_default, :boolean, default: false

    belongs_to :user, Meridian.Accounts.User

    timestamps()
  end

  @doc false
  def changeset(persona, attrs) do
    persona
    |> cast(attrs, [:slug, :name, :system_prompt, :model, :params, :extensions],
      empty_values: [nil]
    )
    |> update_change(:slug, &String.trim/1)
    |> update_change(:name, &String.trim/1)
    |> update_change(:model, &String.trim/1)
    |> validate_required([:slug, :name, :model])
    |> validate_not_blank([:slug, :name, :model])
    |> validate_length(:slug, max: 64)
    |> validate_format(:slug, ~r/^[a-z0-9][a-z0-9_.-]*$/,
      message: "must be lowercase letters, digits, '-', '_' or '.'"
    )
    |> validate_change(:params, fn :params, params ->
      if Map.has_key?(params, "model") or Map.has_key?(params, "messages"),
        do: [params: "must not set \"model\" or \"messages\""],
        else: []
    end)
    |> validate_change(:extensions, fn :extensions, extensions ->
      Enum.map(Meridian.Extensions.settings_errors(extensions), &{:extensions, &1})
    end)
    |> unique_constraint(:slug, name: :personas_user_id_slug_index)
  end

  # `cast` keeps "" (so a system prompt can be cleared), which `validate_required` then
  # doesn't count as missing.
  defp validate_not_blank(changeset, fields) do
    Enum.reduce(fields, changeset, fn field, changeset ->
      validate_change(changeset, field, fn ^field, value ->
        if value == "", do: [{field, {"can't be blank", [validation: :required]}}], else: []
      end)
    end)
  end

  @doc "The model id clients use to select this persona."
  def model_id(%__MODULE__{slug: slug}), do: @model_prefix <> slug

  @doc """
  Extracts the persona slug from a model id, or returns `:error` if the id isn't a persona id.
  """
  def slug_from_model_id(@model_prefix <> slug) when slug != "", do: {:ok, slug}
  def slug_from_model_id(_model_id), do: :error

  @snapshot_fields ~w(id user_id slug name system_prompt model params extensions)a

  @doc """
  The persona's configuration as a plain map, for freezing into a run (`runs.persona_snapshot`).
  """
  def snapshot(%__MODULE__{} = persona) do
    Map.new(@snapshot_fields, fn field -> {Atom.to_string(field), Map.fetch!(persona, field)} end)
  end

  @doc "Rebuilds a (non-persisted) persona from `snapshot/1`."
  def from_snapshot(%{} = snapshot) do
    fields = for field <- @snapshot_fields, do: {field, Map.get(snapshot, Atom.to_string(field))}
    struct!(__MODULE__, fields)
  end
end
