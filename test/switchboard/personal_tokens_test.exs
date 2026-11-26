defmodule Switchboard.PersonalTokensTest do
  use Switchboard.DataCase, async: true

  import Switchboard.OAuthFixtures

  alias Switchboard.{OAuth, PersonalTokens, Scope}
  alias Switchboard.PersonalTokens.PersonalToken

  setup do
    {:ok, scope: Scope.for_user(user_fixture(), via: :browser)}
  end

  test "tokens are shown once, stored hashed and verified", %{scope: scope} do
    assert {:ok, "sb_" <> _ = token, record} = PersonalTokens.create(scope, "  Zed  ", nil)
    assert record.name == "Zed"
    assert record.hint == String.slice(token, 0, 7)
    assert Repo.get!(PersonalToken, record.id).token_hash == OAuth.hash(token)
    refute Repo.exists?(from t in PersonalToken, where: t.token_hash == ^token)

    user_id = scope.user.id
    assert {:ok, %{id: ^user_id}, _} = PersonalTokens.verify(token)
    assert {:error, :invalid_token} = PersonalTokens.verify("sb_wrong")
    assert {:error, :invalid_token} = PersonalTokens.verify("sbat_x")
  end

  test "validation", %{scope: scope} do
    assert {:error, :name_required} = PersonalTokens.create(scope, " ", 30)
    assert {:error, :invalid_expiry} = PersonalTokens.create(scope, "x", 3)
  end

  test "people can only revoke their own tokens", %{scope: scope} do
    {:ok, _token, record} = PersonalTokens.create(scope, "mine", 30)
    other = Scope.for_user(user_fixture())

    assert {:error, :not_found} = PersonalTokens.revoke(other, record.id)
    assert :ok = PersonalTokens.revoke(scope, record.id)
    assert PersonalTokens.list(scope) == []
  end
end
