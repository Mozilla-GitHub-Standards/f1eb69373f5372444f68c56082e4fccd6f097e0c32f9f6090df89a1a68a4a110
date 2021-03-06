defmodule RetWeb.HubChannel do
  @moduledoc "Ret Web Channel for Hubs"

  use RetWeb, :channel

  import Canada, only: [can?: 2]

  alias Ret.{
    Hub,
    Account,
    Repo,
    RoomObject,
    OwnedFile,
    Scene,
    Storage,
    SessionStat,
    Statix,
    WebPushSubscription
  }

  alias RetWeb.{Presence}
  alias RetWeb.Api.V1.{HubView}

  @hub_preloads [
    scene: [:model_owned_file, :screenshot_owned_file, :scene_owned_file],
    scene_listing: [:model_owned_file, :screenshot_owned_file, :scene_owned_file, :scene],
    web_push_subscriptions: []
  ]

  def join(
        "hub:" <> hub_sid,
        %{
          "profile" => profile,
          "context" => context,
          "push_subscription_endpoint" => endpoint,
          "auth_token" => auth_token
        },
        socket
      ) do
    socket |> assign(:profile, profile) |> assign(:context, context) |> perform_join(hub_sid, endpoint, auth_token)
  end

  def join(
        "hub:" <> hub_sid,
        %{"profile" => profile, "context" => context, "push_subscription_endpoint" => endpoint},
        socket
      ) do
    socket |> assign(:profile, profile) |> assign(:context, context) |> perform_join(hub_sid, endpoint)
  end

  def join("hub:" <> hub_sid, %{"profile" => profile, "context" => context}, socket) do
    socket |> assign(:profile, profile) |> assign(:context, context) |> perform_join(hub_sid)
  end

  defp perform_join(socket, hub_sid, push_subscription_endpoint \\ nil, auth_token \\ nil) do
    Hub
    |> Repo.get_by(hub_sid: hub_sid)
    |> Repo.preload(@hub_preloads)
    |> join_with_hub(socket, push_subscription_endpoint, auth_token)
  end

  def handle_in("events:entered", %{"initialOccupantCount" => occupant_count} = payload, socket) do
    socket =
      socket
      |> handle_max_occupant_update(occupant_count)
      |> handle_entered_event(payload)

    Statix.increment("ret.channels.hub.event_entered", 1)

    {:noreply, socket}
  end

  def handle_in("events:entered", payload, socket) do
    socket = socket |> handle_entered_event(payload)

    Statix.increment("ret.channels.hub.event_entered", 1)

    {:noreply, socket}
  end

  def handle_in("events:object_spawned", %{"object_type" => object_type}, socket) do
    socket = socket |> handle_object_spawned(object_type)

    Statix.increment("ret.channels.hub.objects_spawned", 1)

    {:noreply, socket}
  end

  def handle_in("events:request_support", _payload, socket) do
    hub = socket |> hub_for_socket
    Task.start_link(fn -> hub |> Ret.Support.request_support_for_hub() end)

    {:noreply, socket}
  end

  def handle_in("events:profile_updated", %{"profile" => profile}, socket) do
    socket = socket |> assign(:profile, profile) |> broadcast_presence_update
    {:noreply, socket}
  end

  def handle_in("naf" = event, payload, socket) do
    broadcast_from!(socket, event, payload)
    {:noreply, socket}
  end

  def handle_in("message" = event, payload, socket) do
    broadcast!(socket, event, payload |> Map.put(:session_id, socket.assigns.session_id))

    GenServer.cast(DiscordBotManager, %{
      hub_sid: socket.assigns.hub_sid,
      event: :message,
      context: socket.assigns,
      payload: payload
    })

    {:noreply, socket}
  end

  def handle_in("subscribe", %{"subscription" => subscription}, socket) do
    socket
    |> hub_for_socket
    |> WebPushSubscription.subscribe_to_hub(subscription)

    {:noreply, socket}
  end

  def handle_in("unsubscribe", %{"subscription" => subscription}, socket) do
    socket
    |> hub_for_socket
    |> WebPushSubscription.unsubscribe_from_hub(subscription)

    has_remaining_subscriptions = WebPushSubscription.endpoint_has_subscriptions?(subscription["endpoint"])

    {:reply, {:ok, %{has_remaining_subscriptions: has_remaining_subscriptions}}, socket}
  end

  def handle_in("sign_in", %{"token" => token}, socket) do
    case Ret.Guardian.resource_from_token(token) do
      {:ok, %Account{} = account, _claims} ->
        socket = Guardian.Phoenix.Socket.put_current_resource(socket, account)

        hub = socket |> hub_for_socket

        perms_token = get_perms_token(hub, account)

        {:reply, {:ok, %{perms_token: perms_token}}, socket}

      {:error, reason} ->
        {:reply, {:error, %{message: "Sign in failed", reason: reason}}, socket}
    end
  end

  def handle_in("sign_out", _payload, socket) do
    socket = Guardian.Phoenix.Socket.put_current_resource(socket, nil)
    {:reply, {:ok, %{}}, socket}
  end

  def handle_in(
        "pin",
        %{
          "id" => object_id,
          "gltf_node" => gltf_node,
          "file_id" => file_id,
          "file_access_token" => file_access_token,
          "promotion_token" => promotion_token
        },
        socket
      ) do
    with_account(socket, fn account ->
      perform_pin!(object_id, gltf_node, account, socket)
      Storage.promote(file_id, file_access_token, promotion_token, account)
      OwnedFile.set_active(file_id, account.account_id)
    end)
  end

  def handle_in("pin", %{"id" => object_id, "gltf_node" => gltf_node}, socket) do
    with_account(socket, fn account ->
      perform_pin!(object_id, gltf_node, account, socket)
    end)
  end

  def handle_in("unpin", %{"id" => object_id, "file_id" => file_id}, socket) do
    hub = socket |> hub_for_socket

    case Guardian.Phoenix.Socket.current_resource(socket) do
      %Account{} = account ->
        RoomObject.perform_unpin(hub, object_id)
        OwnedFile.set_inactive(file_id, account.account_id)

      _ ->
        nil
    end

    {:noreply, socket}
  end

  def handle_in("unpin", %{"id" => object_id}, socket) do
    hub = socket |> hub_for_socket

    case Guardian.Phoenix.Socket.current_resource(socket) do
      %Account{} = _account ->
        RoomObject.perform_unpin(hub, object_id)

      _ ->
        nil
    end

    {:noreply, socket}
  end

  def handle_in("get_host", _args, socket) do
    hub = socket |> hub_for_socket |> Hub.ensure_host()
    {:reply, {:ok, %{host: hub.host}}, socket}
  end

  def handle_in("update_hub", payload, socket) do
    hub = socket |> hub_for_socket
    account = Guardian.Phoenix.Socket.current_resource(socket)

    if account |> can?(update_hub(hub)) do
      hub
      |> Hub.add_name_to_changeset(payload)
      |> Repo.update!()
      |> Repo.preload(@hub_preloads)
      |> broadcast_hub_refresh!(socket, ["name"])
    end

    {:noreply, socket}
  end

  def handle_in("update_scene", %{"url" => url}, socket) do
    hub = socket |> hub_for_socket |> Repo.preload([:scene, :scene_listing])
    account = Guardian.Phoenix.Socket.current_resource(socket)

    if account |> can?(update_hub(hub)) do
      endpoint_host = RetWeb.Endpoint.host()

      case url |> URI.parse() do
        %URI{host: ^endpoint_host, path: "/scenes/" <> scene_path} ->
          scene_or_listing = scene_path |> String.split("/") |> Enum.at(0) |> Scene.scene_or_scene_listing_by_sid()
          hub |> Hub.changeset_for_new_scene(scene_or_listing)

        _ ->
          hub |> Hub.changeset_for_new_environment_url(url)
      end
      |> Repo.update!()
      |> Repo.preload(@hub_preloads, force: true)
      |> broadcast_hub_refresh!(socket, ["scene"])
    end

    {:noreply, socket}
  end

  def handle_in("refresh_perms_token", _args, socket) do
    account = Guardian.Phoenix.Socket.current_resource(socket)
    perms_token = socket |> hub_for_socket |> get_perms_token(account)
    {:reply, {:ok, %{perms_token: perms_token}}, socket}
  end

  def handle_in("kick", %{"session_id" => session_id}, socket) do
    account = Guardian.Phoenix.Socket.current_resource(socket)
    hub = socket |> hub_for_socket

    if account |> can?(kick_users(hub)) do
      RetWeb.Endpoint.broadcast("session:#{session_id}", "disconnect", %{})
    end

    {:noreply, socket}
  end

  def handle_in(_message, _payload, socket) do
    {:noreply, socket}
  end

  defp with_account(socket, handler) do
    case Guardian.Phoenix.Socket.current_resource(socket) do
      %Account{} = account ->
        handler.(account)
        {:reply, {:ok, %{}}, socket}

      _ ->
        # client should have signed-in at this point,
        # so if we still don't have an account, it must have been an invalid token
        {:reply, {:error, %{reason: :invalid_token}}, socket}
    end
  end

  def handle_info({:begin_tracking, session_id, _hub_sid}, socket) do
    {:ok, _} = Presence.track(socket, session_id, socket |> presence_meta_for_socket)
    push(socket, "presence_state", socket |> Presence.list())

    {:noreply, socket}
  end

  def handle_info(_message, socket) do
    {:noreply, socket}
  end

  defp perform_pin!(object_id, gltf_node, account, socket) do
    hub = socket |> hub_for_socket
    RoomObject.perform_pin!(hub, account, %{object_id: object_id, gltf_node: gltf_node})
    broadcast_pinned_media(socket, object_id, gltf_node)
  end

  def terminate(_reason, socket) do
    socket
    |> SessionStat.stat_query_for_socket()
    |> Repo.update_all(set: [ended_at: NaiveDateTime.utc_now()])

    GenServer.cast(DiscordBotManager, %{hub_sid: socket.assigns.hub_sid, event: :part, context: socket.assigns})

    :ok
  end

  defp broadcast_presence_update(socket) do
    Presence.update(socket, socket.assigns.session_id, socket |> presence_meta_for_socket)
    socket
  end

  defp broadcast_pinned_media(socket, object_id, gltf_node) do
    broadcast!(socket, "pin", %{object_id: object_id, gltf_node: gltf_node, pinned_by: socket.assigns.session_id})
  end

  # Broadcasts the full hub info as well as an (optional) list of specific fields which
  # clients should consider stale and need to be updated in client state from the new
  # hub info
  #
  # Note this doesn't necessarily mean the fields have changed.
  #
  # For example, if the scene needs to be refreshed, this message indicates that by including
  # "scene" in the list of stale fields.
  defp broadcast_hub_refresh!(hub, socket, stale_fields) do
    response =
      HubView.render("show.json", %{hub: hub})
      |> Map.put(:session_id, socket.assigns.session_id)
      |> Map.put(:stale_fields, stale_fields)

    broadcast!(socket, "hub_refresh", response)
  end

  defp presence_meta_for_socket(socket) do
    socket.assigns |> Map.take([:presence, :profile, :context])
  end

  defp join_with_hub(%Hub{entry_mode: :deny}, _socket, _endpoint, _auth_token) do
    {:error, %{message: "Hub no longer accessible", reason: "closed"}}
  end

  defp join_with_hub(%Hub{} = hub, socket, push_subscription_endpoint, auth_token) do
    hub = hub |> Hub.ensure_valid_entry_code!() |> Hub.ensure_host()

    is_push_subscribed =
      push_subscription_endpoint &&
        hub.web_push_subscriptions |> Enum.any?(&(&1.endpoint == push_subscription_endpoint))

    socket =
      case Ret.Guardian.resource_from_token(auth_token) do
        {:ok, %Account{} = account, _claims} -> Guardian.Phoenix.Socket.put_current_resource(socket, account)
        _ -> socket
      end

    with socket <- socket |> assign(:hub_sid, hub.hub_sid) |> assign(:presence, :lobby),
         response <- HubView.render("show.json", %{hub: hub}) do
      response = response |> Map.put(:subscriptions, %{web_push: is_push_subscribed})

      account = socket |> Guardian.Phoenix.Socket.current_resource()

      perms_token = get_perms_token(hub, account)

      response = response |> Map.put(:perms_token, perms_token)

      existing_stat_count =
        socket
        |> SessionStat.stat_query_for_socket()
        |> Repo.all()
        |> length

      unless existing_stat_count > 0 do
        with session_id <- socket.assigns.session_id,
             started_at <- socket.assigns.started_at,
             stat_attrs <- %{session_id: session_id, started_at: started_at},
             changeset <- %SessionStat{} |> SessionStat.changeset(stat_attrs) do
          Repo.insert(changeset)
        end
      end

      send(self(), {:begin_tracking, socket.assigns.session_id, hub.hub_sid})

      # Send join push notification if this is the first joiner
      if Presence.list(socket.topic) |> Enum.count() == 0 do
        Task.start_link(fn -> hub |> Hub.send_push_messages_for_join(push_subscription_endpoint) end)
      end

      GenServer.cast(DiscordBotManager, %{hub_sid: socket.assigns.hub_sid, event: :join, context: socket.assigns})

      Statix.increment("ret.channels.hub.joins.ok")

      {:ok, response, socket}
    end
  end

  defp join_with_hub(nil, _socket, _endpoint, _auth_token) do
    Statix.increment("ret.channels.hub.joins.not_found")

    {:error, %{message: "No such Hub"}}
  end

  defp get_perms_token(hub, account) do
    account_id = if account, do: account.account_id, else: nil

    hub
    |> Hub.perms_for_account(account)
    |> Account.add_global_perms_for_account(account)
    |> Map.put(:account_id, account_id)
    |> Map.put(:hub_id, hub.hub_sid)
    |> Ret.PermsToken.token_for_perms()
  end

  defp handle_entered_event(socket, payload) do
    stat_attributes = [entered_event_payload: payload, entered_event_received_at: NaiveDateTime.utc_now()]

    # Flip context to have HMD if entered with display type
    socket =
      with %{"entryDisplayType" => display} when is_binary(display) and display != "Screen" <- payload,
           %{context: context} when is_map(context) <- socket.assigns do
        socket |> assign(:context, context |> Map.put("hmd", true))
      else
        _ -> socket
      end

    socket
    |> SessionStat.stat_query_for_socket()
    |> Repo.update_all(set: stat_attributes)

    socket |> assign(:presence, :room) |> broadcast_presence_update
  end

  defp handle_max_occupant_update(socket, occupant_count) do
    socket
    |> hub_for_socket
    |> Hub.changeset_for_new_seen_occupant_count(occupant_count)
    |> Repo.update!()

    socket
  end

  defp handle_object_spawned(socket, object_type) do
    socket
    |> hub_for_socket
    |> Hub.changeset_for_new_spawned_object_type(object_type)
    |> Repo.update!()

    socket
  end

  defp hub_for_socket(socket) do
    Repo.get_by(Hub, hub_sid: socket.assigns.hub_sid)
  end
end
