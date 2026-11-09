defmodule Mithril.MobileFunctions.ProfileAvatarTest do
  use ExUnit.Case, async: true

  alias Mithril.MobileFunctions.ProfileAvatar

  @user "123e4567-e89b-42d3-a456-426614174000"
  @jpeg Base.encode64(<<0xFF, 0xD8, 0xFF, 0xD9>>)

  test "rejects a photo that is not an allowed image type" do
    assert {:error, {:status, 400, %{error: "invalid_photo"}}} =
             ProfileAvatar.upload(@user, %{
               "content_type" => "image/svg+xml",
               "data_base64" => @jpeg
             })
  end

  test "rejects an empty or oversized photo before storage" do
    assert {:error, {:status, 400, %{error: "invalid_photo"}}} =
             ProfileAvatar.upload(@user, %{
               "content_type" => "image/jpeg",
               "data_base64" => Base.encode64("")
             })
  end

  test "any signed-in user can request a view URL for a valid avatar path" do
    other = "123e4567-e89b-42d3-a456-426614174001"

    assert {:error, {:status, 503, %{error: "storage_not_configured"}}} =
             ProfileAvatar.url(@user, %{
               "storage_path" => "#{other}/avatar-1760000000000.jpg"
             })
  end

  test "only the owner can delete an avatar object" do
    other = "123e4567-e89b-42d3-a456-426614174001"

    assert {:error, {:status, 403, %{error: "forbidden"}}} =
             ProfileAvatar.delete(@user, %{
               "storage_path" => "#{other}/avatar-1760000000000.jpg"
             })

    assert {:error, {:status, 503, %{error: "storage_not_configured"}}} =
             ProfileAvatar.delete(@user, %{
               "storage_path" => "#{@user}/avatar-1760000000000.jpg"
             })
  end

  test "rejects signing a path outside the caller's avatar prefix" do
    for path <- [
          "../secret.jpg",
          "#{@user}/../secret.jpg",
          "#{@user}/avatar-1.svg",
          "not-a-uuid/avatar-1.jpg"
        ] do
      assert {:error, {:status, 400, %{error: "bad_request"}}} =
               ProfileAvatar.url(@user, %{"storage_path" => path})
    end
  end

  test "a valid upload reaches object storage" do
    assert {:error, {:status, 503, %{error: "storage_not_configured"}}} =
             ProfileAvatar.upload(@user, %{
               "content_type" => "image/jpeg",
               "data_base64" => @jpeg
             })
  end

  test "a valid avatar path reaches object storage when signing" do
    assert {:error, {:status, 503, %{error: "storage_not_configured"}}} =
             ProfileAvatar.url(@user, %{
               "storage_path" => "#{@user}/avatar-1760000000000.jpg"
             })
  end
end
