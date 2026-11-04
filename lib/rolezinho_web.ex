defmodule RolezinhoWeb do
  @moduledoc """
  The entrypoint for defining your web interface, such
  as controllers, components, channels, and so on.

  This can be used in your application as:

      use RolezinhoWeb, :controller
      use RolezinhoWeb, :html

  The definitions below will be executed for every controller,
  component, etc, so keep them short and clean, focused
  on imports, uses and aliases.

  Do NOT define functions inside the quoted expressions
  below. Instead, define additional modules and import
  those modules here.
  """

  def static_paths,
    do: ~w(assets fonts images favicon.ico robots.txt manifest.webmanifest)

  def router do
    quote do
      use Phoenix.Router, helpers: false

      # Import common connection and controller functions to use in pipelines
      import Plug.Conn
      import Phoenix.Controller
      import Phoenix.LiveView.Router
    end
  end

  def channel do
    quote do
      use Phoenix.Channel
    end
  end

  def controller do
    quote do
      use Phoenix.Controller, formats: [:html, :json]

      use Gettext, backend: RolezinhoWeb.Gettext

      import Plug.Conn

      unquote(verified_routes())
    end
  end

  def live_view do
    quote do
      use Phoenix.LiveView

      unquote(html_helpers())
    end
  end

  def live_component do
    quote do
      use Phoenix.LiveComponent

      unquote(html_helpers())
    end
  end

  def html do
    quote do
      use Phoenix.Component

      # Import convenience functions from controllers
      import Phoenix.Controller,
        only: [get_csrf_token: 0, view_module: 1, view_template: 1]

      # Include general helpers for rendering HTML
      unquote(html_helpers())
    end
  end

  defp html_helpers do
    quote do
      # Translation
      use Gettext, backend: RolezinhoWeb.Gettext

      # HTML escaping functionality
      import Phoenix.HTML
      # Core UI components
      import RolezinhoWeb.CoreComponents

      # Design system components (one module per component under components/ui/,
      # cataloged in /storybook — see DESIGN.md, section 5)
      import RolezinhoWeb.Components.UI.AlertBanner
      import RolezinhoWeb.Components.UI.Avatar
      # Only the component: show/1 and hide/1 would collide with CoreComponents,
      # so they stay qualified (BottomSheet.show("join")).
      import RolezinhoWeb.Components.UI.BottomSheet, only: [bottom_sheet: 1]
      import RolezinhoWeb.Components.UI.Button
      import RolezinhoWeb.Components.UI.Card
      import RolezinhoWeb.Components.UI.Coachmark
      import RolezinhoWeb.Components.UI.DateTimeField
      import RolezinhoWeb.Components.UI.EmptyState
      import RolezinhoWeb.Components.UI.EventCard
      import RolezinhoWeb.Components.UI.FieldConfigRow
      import RolezinhoWeb.Components.UI.FilterChips
      import RolezinhoWeb.Components.UI.IconButton
      import RolezinhoWeb.Components.UI.InfoTile
      import RolezinhoWeb.Components.UI.InviteCard
      import RolezinhoWeb.Components.UI.ParticipantRow
      import RolezinhoWeb.Components.UI.PixQR
      import RolezinhoWeb.Components.UI.ProgressBar
      import RolezinhoWeb.Components.UI.RoleCard
      import RolezinhoWeb.Components.UI.SearchField
      import RolezinhoWeb.Components.UI.SectionHeader
      import RolezinhoWeb.Components.UI.SegmentedControl
      import RolezinhoWeb.Components.UI.SplitMethodFields
      import RolezinhoWeb.Components.UI.SharePreview
      import RolezinhoWeb.Components.UI.Skeleton
      import RolezinhoWeb.Components.UI.StatusPill
      import RolezinhoWeb.Components.UI.Stepper
      import RolezinhoWeb.Components.UI.SwipeActions
      import RolezinhoWeb.Components.UI.TextField
      import RolezinhoWeb.Components.UI.Toast
      import RolezinhoWeb.Components.UI.ToggleChip

      # Common modules used in templates
      alias Phoenix.LiveView.JS
      alias RolezinhoWeb.Layouts

      # Routes generation with the ~p sigil
      unquote(verified_routes())
    end
  end

  def verified_routes do
    quote do
      use Phoenix.VerifiedRoutes,
        endpoint: RolezinhoWeb.Endpoint,
        router: RolezinhoWeb.Router,
        statics: RolezinhoWeb.static_paths()
    end
  end

  @doc """
  When used, dispatch to the appropriate controller/live_view/etc.
  """
  defmacro __using__(which) when is_atom(which) do
    apply(__MODULE__, which, [])
  end
end
