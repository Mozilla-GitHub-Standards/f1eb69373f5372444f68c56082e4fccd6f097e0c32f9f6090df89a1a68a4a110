defmodule RetWeb.Api.V1.OAuthController do
  use RetWeb, :controller

  plug(RetWeb.Plugs.RateLimit when action in [:show])

  def show(conn, %{"type" => "discord", "state" => state, "code" => code}) do
    {:ok, %{"hub_sid" => hub_sid}} = Ret.OAuthToken.decode_and_verify(state)

    %{"id" => discord_user_id, "email" => email, "verified" => verified} =
      code |> Ret.DiscordClient.fetch_access_token() |> Ret.DiscordClient.fetch_user_info()

    hub = Ret.Hub |> Ret.Repo.get_by(hub_sid: hub_sid) |> Ret.Repo.preload(:hub_bindings)

    conn
    |> process_oauth(discord_user_id, email, verified, hub)
    |> put_resp_header("location", hub |> Ret.Hub.url_for())
    |> send_resp(307, "")
  end

  # Discord user has a verified email, so we create a Hubs account for them associate it with their discord user id.
  defp process_oauth(conn, discord_user_id, email, true = _verified, _hub) do
    account = email |> Ret.Account.account_for_email()

    oauth_provider = Ret.OAuthProvider |> Ret.Repo.get_by(source: :discord, account_id: account.account_id)

    (oauth_provider || %Ret.OAuthProvider{source: :discord, account: account})
    |> Ecto.Changeset.change(provider_account_id: discord_user_id)
    |> Ret.Repo.insert_or_update()

    credentials = %{
      email: email,
      token: email |> Ret.Account.account_for_email() |> Ret.Account.credentials_for_account()
    }

    conn |> put_short_lived_cookie("ret-oauth-flow-account-credentials", credentials |> Poison.encode!())
  end

  # Discord user does not have a verified email, so we can't create an account for them. Instead, we generate a perms
  # token to let them join the hub if permitted.
  defp process_oauth(conn, discord_user_id, email, false = _verified, hub) do
    hub_binding = hub.hub_bindings |> Enum.find(&(&1.type == :discord))

    can_join_hub =
      discord_user_id |> Ret.DiscordClient.member_of_channel?(hub_binding.community_id, hub_binding.channel_id)

    perms_token =
      %{
        join_hub: can_join_hub,
        kick_users: false
      }
      |> Ret.PermsToken.token_for_perms()

    conn |> put_short_lived_cookie("ret-oauth-flow-perms-token", perms_token)
  end

  defp put_short_lived_cookie(conn, key, value) do
    conn |> put_resp_cookie(key, value, http_only: false, max_age: 5 * 60)
  end
end