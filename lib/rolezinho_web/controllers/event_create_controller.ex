defmodule RolezinhoWeb.EventCreateController do
  @moduledoc """
  Creates an event and hands the organizer their secret.

  A controller rather than a LiveView event for the same structural reason
  joining is one: the organizer token has to land in the session to survive the
  next page load, and a LiveView cannot write there. Creating through a real
  request is what makes "whoever creates is the organizer" (RN-20) true for
  someone who is not the environment-wide admin.

  Without this, opening creation to everyone would hand people an event they
  could not administer — the token would exist in the database and nowhere else.

  When a `group` slug arrives with the request, the event is created inside
  that group only if the caller has enough access to edit the group (admin, or
  the group is password-protected and unlocked in this session). Otherwise the
  event still gets created — but ungrouped, with a flash explaining why. This
  is deliberate: silently attaching to a group anyone can name would let a
  visitor drop noise into someone else's bundle.
  """
  use RolezinhoWeb, :controller

  alias Rolezinho.Group
  alias Rolezinho.Groups
  alias Rolezinho.Events
  alias RolezinhoWeb.Plugs.Participant

  # A group's edit-access check now also considers the signed-in creator of
  # the group (per ADR-0002), so we pass `current_user_id` through here.

  def create(conn, %{"event" => params}) do
    params = RolezinhoWeb.AccessCodeField.to_password(params)
    admin? = conn.assigns.current_admin?
    current_user = conn.assigns[:current_user]
    unlocked_groups = conn.assigns[:unlocked_groups] || MapSet.new()
    requested_group_slug = params |> Map.get("group", "") |> to_string() |> String.trim()

    # ADR-0002: creation requires either a signed-in user or the admin
    # bypass. Enforcement lives here too (the LiveView also redirects); a
    # missing user without admin at this point means the POST arrived
    # without going through the form.
    cond do
      is_nil(current_user) and not admin? ->
        conn
        |> put_flash(:info, "Entra com o GitHub pra criar.")
        |> redirect(
          to: "/entrar?" <> URI.encode_query(return_to: back_to_form(requested_group_slug))
        )

      true ->
        do_create(conn, params, requested_group_slug, admin?, current_user, unlocked_groups)
    end
  end

  defp do_create(conn, params, requested_group_slug, admin?, current_user, unlocked_groups) do
    current_user_id = current_user && current_user.id

    {group_id, group_flash, requested_group} =
      resolve_group(requested_group_slug, admin?, unlocked_groups, current_user_id)

    # `admin?:` on the opts still means "the born-hidden mitigation doesn't
    # apply". Under ADR-0002 a signed-in creator gets the same treatment via
    # `created_by_user_id:`, so we don't need to sneak `admin?: true` in for
    # them just to reach `:active`.
    create_opts =
      [group_id: group_id, created_by_user_id: current_user_id]
      |> then(fn opts -> if admin?, do: [{:admin?, true} | opts], else: opts end)

    case Events.create(params, create_opts) do
      {:ok, event} ->
        conn
        |> Participant.put_organizer_token(event.slug, event.organizer_token)
        |> put_flash(:info, create_flash(admin?, group_id))
        |> maybe_group_flash(group_flash)
        |> redirect(to: redirect_target(event, requested_group))

      {:error, _errors} ->
        # The form posts, so a rejection cannot re-render in place. Rather than
        # smuggling every field back through the query string, it returns to the
        # empty form with the reason — the alternative was a URL carrying the
        # description in it.
        conn
        |> put_flash(:error, "Confira os campos e tente de novo.")
        |> redirect(to: back_to_form(requested_group_slug))
    end
  end

  # `nil` when either no group was named, or one was named but the caller has
  # no right to add events to it. The second case ships a flash — a silent
  # "we ignored your group" would be surprising.
  defp resolve_group("", _admin?, _unlocked, _user_id), do: {nil, nil, nil}

  defp resolve_group(slug, admin?, unlocked_groups, current_user_id) do
    case Groups.find(slug) do
      nil ->
        {nil, "Grupo não encontrado. O rolê foi criado fora de grupo.", nil}

      %Group{} = group ->
        if Group.editable_by?(group, admin?, unlocked_groups, current_user_id) do
          {group.id, nil, group}
        else
          {nil,
           "Você não tem acesso pra adicionar rolês nesse grupo. O rolê foi criado fora dele.",
           nil}
        end
    end
  end

  defp maybe_group_flash(conn, nil), do: conn
  # `:info` from the success flash already fills the info slot; use `:error` to
  # surface that something the caller asked for did not happen.
  defp maybe_group_flash(conn, message), do: put_flash(conn, :error, message)

  # Under ADR-0002 signed-in-user and admin creations both come out `:active`,
  # so the same flash fits either. The only real branch left is "you created
  # inside a group" — that goes to the group page, not the home page.
  defp create_flash(_admin?, group_id) when not is_nil(group_id),
    do: "Rolezinho criado no grupo!"

  defp create_flash(_admin?, _), do: "Rolezinho criado! Manda o link no grupo."

  # When creation was requested inside a valid group, send the organizer back to
  # the group so they see the new event in context.
  defp redirect_target(_event, %Group{} = group), do: ~p"/g/#{group.slug}"
  defp redirect_target(event, _), do: ~p"/r/#{event.slug}"

  defp back_to_form(""), do: ~p"/criar"
  defp back_to_form(slug), do: ~p"/criar?group=#{slug}"
end
