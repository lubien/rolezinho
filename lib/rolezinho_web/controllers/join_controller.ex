defmodule RolezinhoWeb.JoinController do
  @moduledoc """
  Puts someone on a list and issues the identity that keeps the row theirs.

  This is a controller rather than a LiveView event for one structural reason: a
  LiveView cannot write to the session, and the participant id has to land there
  to survive the next page load. So joining goes through a real request, and
  from then on the LiveView reads the id the session already holds.

  The id is issued here and never accepted from the client — a browser that
  could choose its own id could choose one already on somebody else's row.
  """
  use RolezinhoWeb, :controller

  alias Rolezinho.Event
  alias Rolezinho.Event.Policy
  alias Rolezinho.Event.Token
  alias Rolezinho.Events
  alias Rolezinho.Group
  alias Rolezinho.Groups
  alias RolezinhoWeb.Plugs.Admin
  alias RolezinhoWeb.Plugs.Participant

  def create(conn, %{"slug" => slug} = params) do
    name = params |> Map.get("name", "") |> to_string()
    size = params |> Map.get("qty") |> parse_size()

    case Events.find(slug, visibility: :public) do
      %Event{} = event -> join(conn, event, name, size, params)
      nil -> not_found(conn)
    end
  end

  defp join(conn, %Event{} = event, name, size, params) do
    # ADR-0002: a signed-in user's rows carry their `user_id` as a second
    # identity, so any future session where they sign in with the same
    # GitHub account can act on the row (mark paid, leave the list) even
    # after the per-device `participant_id` is gone. Nil for anonymous
    # joins — in that case only the token identifies the row.
    user_id = conn.assigns[:current_user_id]
    guest_names = parse_guest_names(params["guest_names"])

    with :ok <- ensure_unlocked(conn, event),
         :ok <- ensure_open(conn, event),
         {:ok, values} <- collect_answers(event, params),
         participant_id <- Token.generate_participant(),
         {:ok, _updated, placed} <-
           Events.add_party(event, name, size,
             participant_id: participant_id,
             user_id: user_id,
             values: values,
             guest_names: guest_names
           ) do
      conn
      |> Participant.put_participant(event.slug, participant_id)
      |> put_flash(:info, placement_message(placed))
      |> redirect(to: next_step(event))
    else
      {:error, reason} ->
        conn
        |> put_flash(:error, message_for(reason))
        |> redirect(to: ~p"/r/#{event.slug}")
    end
  end

  # A party can be split across both lists, so the message says what actually
  # happened rather than assuming everyone got a slot.
  defp placement_message(%{main: main, wait: 0}), do: "#{people(main)} na lista!"
  defp placement_message(%{main: 0, wait: wait}), do: "#{people(wait)} na espera."

  defp placement_message(%{main: main, wait: wait}) do
    "#{people(main)} na lista e #{people(wait)} na espera."
  end

  defp people(1), do: "Você entrou"
  defp people(count), do: "#{count} entraram"

  # Paying is the next thing on someone's mind after getting a slot, so a paid
  # event routes there instead of dropping them back on the list to find the
  # key themselves (RN-11).
  defp next_step(%Event{} = event) do
    if payable?(event), do: ~p"/r/#{event.slug}/pagamento", else: ~p"/r/#{event.slug}"
  end

  defp payable?(%Event{pix_key: key} = event) do
    is_integer(Rolezinho.Event.Cash.per_person_cents(event)) and is_binary(key) and key != ""
  end

  # Answers to the organizer's questions (RN-62). Only the fields this event
  # actually asks for are read: anything else in the body is somebody sending
  # keys nobody asked about, and it does not get stored.
  #
  # Two-step: first enforce required-field presence against the raw params
  # (the join screen is the one moment we *ask* for these, so a missing
  # required field is an error, not a silent drop); then delegate the actual
  # trim/cap/allow-list shaping to `Events.sanitize_answers/2` so the join
  # and edit paths agree on what a valid stored value looks like.
  defp collect_answers(%Event{} = event, params) do
    fields = event |> Events.form_fields() |> Enum.reject(& &1.locked)

    missing =
      Enum.find(fields, fn field ->
        field.required and
          params |> Map.get(field.id, "") |> to_string() |> String.trim() == ""
      end)

    case missing do
      nil -> {:ok, Events.sanitize_answers(event, params)}
      field -> {:error, {:missing_field, field.label}}
    end
  end

  # A party size arriving from the client is bounded here, not trusted: the
  # stepper stops at nine, but the request does not have to come from it.
  defp parse_size(nil), do: 1

  defp parse_size(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {size, ""} when size >= 1 -> min(size, Event.max_party_size())
      _ -> 1
    end
  end

  defp parse_size(_), do: 1

  # HTML forms with repeated `guest_names[]` inputs arrive as either a
  # list (typical) or an index-keyed map (some plug versions). Coerce to
  # a plain list of strings; anything else means the form did not send
  # per-guest names, and the caller falls back to "Convidado de X".
  defp parse_guest_names(nil), do: []

  defp parse_guest_names(values) when is_list(values),
    do: Enum.map(values, &to_string/1)

  defp parse_guest_names(values) when is_map(values) do
    values
    |> Enum.sort_by(fn {k, _} -> k end)
    |> Enum.map(fn {_, v} -> to_string(v) end)
  end

  defp parse_guest_names(_), do: []

  # A password-gated event has to be unlocked before anyone can join it, or the
  # gate would only be hiding the list rather than protecting it. The same
  # applies when the event lives in a password-protected group: joining is one
  # of the operations the group gate is supposed to prevent.
  defp ensure_unlocked(conn, %Event{} = event) do
    admin? = conn.assigns.current_admin?

    unlocked? =
      cond do
        admin? -> true
        group_password_bypass?(conn, event) -> true
        group_password_gates?(event) -> false
        not Event.password_protected?(event) -> true
        MapSet.member?(Admin.unlocked_events(conn), event.slug) -> true
        true -> false
      end

    if unlocked?, do: :ok, else: {:error, :locked}
  end

  defp group_password_bypass?(_conn, %Event{group_id: nil}), do: false

  defp group_password_bypass?(conn, %Event{group_id: gid}) do
    with %Group{} = group <- Groups.get(gid),
         true <- Group.password_protected?(group) do
      MapSet.member?(Admin.unlocked_groups(conn), group.slug)
    else
      _ -> false
    end
  end

  defp group_password_gates?(%Event{group_id: nil}), do: false

  defp group_password_gates?(%Event{group_id: gid}) do
    case Groups.get(gid) do
      %Group{} = group -> Group.password_protected?(group)
      _ -> false
    end
  end

  defp ensure_open(conn, %Event{} = event) do
    opts = [
      admin?: conn.assigns.current_admin?,
      organizer?: Participant.organizer?(conn, event)
    ]

    if Policy.can_join?(event, opts), do: :ok, else: {:error, :signups_locked}
  end

  defp not_found(conn) do
    conn
    |> put_flash(:error, "Rolezinho não encontrado.")
    |> redirect(to: ~p"/")
  end

  defp message_for(:locked), do: "Precisa da senha pra entrar nesse rolezinho."
  defp message_for(:signups_locked), do: "Este rolezinho está fechado para novas inscrições."
  defp message_for(:main_full), do: "Lista principal cheia."
  defp message_for(:empty_name), do: "Digite um nome."
  defp message_for(:wait_disabled), do: "Este rolezinho não tem lista de reserva."
  defp message_for(:invalid_party_size), do: "Escolha de 1 a 9 pessoas."

  defp message_for(:party_does_not_fit),
    do: "Não tem vaga pra todo mundo, e esse rolê não tem lista de espera."

  defp message_for({:missing_field, label}), do: "Preencha #{label}."

  defp message_for(_), do: "Não deu pra entrar na lista."
end
