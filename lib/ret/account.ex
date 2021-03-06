defmodule Ret.Account do
  use Ecto.Schema
  import Ecto.Query

  alias Ret.{Repo, Account, Login, Guardian}

  @schema_prefix "ret0"
  @primary_key {:account_id, :id, autogenerate: true}

  schema "accounts" do
    field(:min_token_issued_at, :utc_datetime)
    field(:is_admin, :boolean)
    has_one(:login, Ret.Login, foreign_key: :account_id)
    has_many(:owned_files, Ret.OwnedFile, foreign_key: :account_id)
    has_many(:created_hubs, Ret.Hub, foreign_key: :created_by_account_id)
    timestamps()
  end

  def account_for_email(email) do
    email |> identifier_hash_for_email |> account_for_identifier_hash
  end

  def account_for_identifier_hash(identifier_hash) do
    login =
      Login
      |> where([t], t.identifier_hash == ^identifier_hash)
      |> Repo.one()

    if login do
      Account |> Repo.get(login.account_id) |> Repo.preload(:login)
    else
      Repo.insert!(%Account{login: %Login{identifier_hash: identifier_hash}})
    end
  end

  def credentials_for_identifier_hash(identifier_hash) do
    identifier_hash
    |> account_for_identifier_hash
    |> credentials_for_account
  end

  defp credentials_for_account(account) do
    {:ok, token, _claims} = account |> Guardian.encode_and_sign()
    token
  end

  def identifier_hash_for_email(email) do
    email |> String.downcase() |> Ret.Crypto.hash()
  end

  def add_global_perms_for_account(perms, %Ret.Account{is_admin: true}) do
    perms |> Map.put(:postgrest_role, :ret_admin)
  end

  def add_global_perms_for_account(perms, _), do: perms
end
