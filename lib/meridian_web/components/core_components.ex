defmodule MeridianWeb.CoreComponents do
  @moduledoc """
  The small set of UI components used by the admin console. Styling lives in
  `priv/static/assets/admin.css`; there is no CSS framework or asset build.
  """
  use Phoenix.Component

  alias Phoenix.LiveView.JS

  @doc "Renders a flash notice."
  attr :flash, :map, default: %{}
  attr :kind, :atom, values: [:info, :error]

  def flash(assigns) do
    ~H"""
    <div
      :if={msg = Phoenix.Flash.get(@flash, @kind)}
      id={"flash-#{@kind}"}
      class={"flash flash-#{@kind}"}
      role="alert"
      phx-click={JS.push("lv:clear-flash", value: %{key: @kind}) |> JS.hide(to: "#flash-#{@kind}")}
    >
      {msg}
    </div>
    """
  end

  @doc "Renders the info and error flash notices."
  attr :flash, :map, required: true

  def flash_group(assigns) do
    ~H"""
    <.flash kind={:info} flash={@flash} />
    <.flash kind={:error} flash={@flash} />
    """
  end

  @doc "Renders a page (or, with `level={2}`, section) header with optional subtitle and actions."
  attr :level, :integer, values: [1, 2], default: 1
  slot :inner_block, required: true
  slot :subtitle
  slot :actions

  def header(assigns) do
    ~H"""
    <header class={["page-header", @level == 2 && "section-header"]}>
      <div>
        <.dynamic_tag tag_name={"h#{@level}"}>{render_slot(@inner_block)}</.dynamic_tag>
        <p :if={@subtitle != []} class="muted">{render_slot(@subtitle)}</p>
      </div>
      <div :if={@actions != []} class="actions">{render_slot(@actions)}</div>
    </header>
    """
  end

  @doc "Renders a button."
  attr :type, :string, default: "submit"
  attr :variant, :string, values: ~w(primary secondary danger), default: "primary"
  attr :rest, :global, include: ~w(disabled form name value)
  slot :inner_block, required: true

  def button(assigns) do
    ~H"""
    <button type={@type} class={"btn btn-#{@variant}"} {@rest}>
      {render_slot(@inner_block)}
    </button>
    """
  end

  @doc """
  Renders a labelled form input with its errors.

  Types: `text` (and other plain input types), `textarea`, `select`, `checkbox`, and
  `checkgroup` (a set of checkboxes submitting a list).
  """
  attr :id, :any, default: nil
  attr :name, :any
  attr :label, :string, default: nil
  attr :value, :any
  attr :type, :string, default: "text"
  attr :field, Phoenix.HTML.FormField
  attr :errors, :list, default: []
  attr :hint, :string, default: nil
  attr :description, :string, default: nil, doc: "checkboxes only: shown right after the label"
  attr :options, :list, default: []
  attr :prompt, :string, default: nil
  attr :checked, :boolean
  attr :rest, :global, include: ~w(autocomplete disabled list maxlength placeholder readonly
                                   required rows spellcheck autofocus)

  def input(%{field: %Phoenix.HTML.FormField{} = field} = assigns) do
    errors = if Phoenix.Component.used_input?(field), do: field.errors, else: []

    assigns
    |> assign(field: nil, id: assigns.id || field.id)
    |> assign(:errors, Enum.map(errors, &translate_error/1))
    |> assign_new(:name, fn ->
      if assigns.type == "checkgroup", do: field.name <> "[]", else: field.name
    end)
    |> assign_new(:value, fn -> field.value end)
    |> input()
  end

  def input(%{type: "checkbox"} = assigns) do
    assigns =
      assign_new(assigns, :checked, fn ->
        Phoenix.HTML.Form.normalize_value("checkbox", assigns[:value])
      end)

    ~H"""
    <div class="field field-checkbox">
      <label>
        <input type="hidden" name={@name} value="false" />
        <input type="checkbox" id={@id} name={@name} value="true" checked={@checked} {@rest} />
        {@label}<span :if={@description not in [nil, ""]} class="inline-hint">{@description}</span>
      </label>
      <p :if={@hint} class="hint">{@hint}</p>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  def input(%{type: "checkgroup"} = assigns) do
    ~H"""
    <fieldset class="field">
      <legend>{@label}</legend>
      <%!-- Submits an empty list when nothing is checked. --%>
      <input type="hidden" name={@name} value="" />
      <label :for={{label, value} <- @options} class="check">
        <input type="checkbox" name={@name} value={value} checked={value in (@value || [])} />
        {label}
      </label>
      <p :if={@hint} class="hint">{@hint}</p>
      <.error :for={msg <- @errors}>{msg}</.error>
    </fieldset>
    """
  end

  def input(%{type: "select"} = assigns) do
    ~H"""
    <div class="field">
      <label for={@id}>{@label}</label>
      <select id={@id} name={@name} {@rest}>
        <option :if={@prompt} value="">{@prompt}</option>
        {Phoenix.HTML.Form.options_for_select(@options, @value)}
      </select>
      <p :if={@hint} class="hint">{@hint}</p>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  def input(%{type: "textarea"} = assigns) do
    ~H"""
    <div class="field">
      <label for={@id}>{@label}</label>
      <textarea id={@id} name={@name} {@rest}>{Phoenix.HTML.Form.normalize_value("textarea", @value)}</textarea>
      <p :if={@hint} class="hint">{@hint}</p>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  def input(assigns) do
    ~H"""
    <div class="field">
      <label for={@id}>{@label}</label>
      <input
        type={@type}
        name={@name}
        id={@id}
        value={Phoenix.HTML.Form.normalize_value(@type, @value)}
        {@rest}
      />
      <p :if={@hint} class="hint">{@hint}</p>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  @doc "Renders a form error message."
  slot :inner_block, required: true

  def error(assigns) do
    ~H"""
    <p class="error">{render_slot(@inner_block)}</p>
    """
  end

  @doc "Renders a table of `rows`, one column per `col` slot."
  attr :id, :string, required: true
  attr :rows, :list, required: true
  attr :empty, :string, default: "Nothing here yet."

  slot :col, required: true do
    attr :label, :string
  end

  slot :action

  def table(assigns) do
    ~H"""
    <table id={@id}>
      <thead>
        <tr>
          <th :for={col <- @col}>{col[:label]}</th>
          <th :if={@action != []}><span class="sr-only">Actions</span></th>
        </tr>
      </thead>
      <tbody>
        <tr :if={@rows == []}>
          <td colspan={length(@col) + if(@action != [], do: 1, else: 0)} class="muted">
            {@empty}
          </td>
        </tr>
        <tr :for={row <- @rows}>
          <td :for={col <- @col}>{render_slot(col, row)}</td>
          <td :if={@action != []} class="row-actions">
            <%= for action <- @action do %>
              {render_slot(action, row)}
            <% end %>
          </td>
        </tr>
      </tbody>
    </table>
    """
  end

  @doc """
  Renders a `<datalist>` of upstream model ids, so model inputs can suggest them while still
  accepting any value.
  """
  attr :id, :string, required: true
  attr :models, :list, required: true

  def model_datalist(assigns) do
    ~H"""
    <datalist id={@id}>
      <option :for={model <- @models} value={model} />
    </datalist>
    """
  end

  @doc "Formats a timestamp for display, or a dash for `nil`."
  def format_time(nil), do: "—"
  def format_time(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M UTC")

  @doc "Interpolates an Ecto changeset error."
  def translate_error({msg, opts}) do
    Enum.reduce(opts, msg, fn {key, value}, acc ->
      String.replace(acc, "%{#{key}}", fn _ -> to_string(value) end)
    end)
  end
end
