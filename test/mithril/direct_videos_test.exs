defmodule Mithril.DirectVideosTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Mithril.DirectVideos
  alias Mithril.Repo

  setup do
    :ok = Sandbox.checkout(Repo)

    [[database]] = Repo.query!("SELECT current_database()").rows

    unless database == "mithril_test" do
      raise "Refusing to recreate Direct video fixtures; expected mithril_test, got #{inspect(database)}"
    end

    for table <- [
          "placement_matches",
          "placement_requests",
          "placement_candidate_profiles",
          "cleaner_data",
          "user_roles",
          "users"
        ] do
      Repo.query!("DROP TABLE IF EXISTS public.#{table} CASCADE")
    end

    Repo.query!("""
    CREATE TABLE public.users (
      id uuid PRIMARY KEY,
      email text
    )
    """)

    Repo.query!("""
    CREATE TABLE public.user_roles (
      user_id uuid NOT NULL,
      role_id text NOT NULL
    )
    """)

    Repo.query!("""
    CREATE TABLE public.cleaner_data (
      user_id uuid PRIMARY KEY,
      verified boolean NOT NULL DEFAULT false,
      status text NOT NULL DEFAULT 'inactive'
    )
    """)

    Repo.query!("""
    CREATE TABLE public.placement_candidate_profiles (
      user_id uuid PRIMARY KEY,
      placement_opt_in boolean NOT NULL DEFAULT false,
      placement_status text NOT NULL DEFAULT 'inactive',
      desired_roles text[] NOT NULL DEFAULT '{}'::text[],
      living_arrangements text[] NOT NULL DEFAULT '{}'::text[],
      employment_types text[] NOT NULL DEFAULT '{}'::text[],
      preferred_languages text[] NOT NULL DEFAULT '{}'::text[],
      intro_video_url text,
      intro_video_thumbnail_url text,
      intro_video_title text,
      updated_at timestamptz NOT NULL DEFAULT now()
    )
    """)

    Repo.query!("""
    CREATE TABLE public.placement_requests (
      id uuid PRIMARY KEY,
      customer_id uuid NOT NULL,
      status text NOT NULL
    )
    """)

    Repo.query!("""
    CREATE TABLE public.placement_matches (
      id uuid PRIMARY KEY,
      placement_request_id uuid NOT NULL,
      candidate_user_id uuid NOT NULL,
      status text NOT NULL
    )
    """)

    :ok
  end

  test "customer can read a video only for a candidate on their shortlist" do
    customer_id = Ecto.UUID.generate()
    other_customer_id = Ecto.UUID.generate()
    candidate_id = Ecto.UUID.generate()
    placement_id = Ecto.UUID.generate()

    insert_user(customer_id)
    insert_user(other_customer_id)
    insert_candidate(candidate_id)
    insert_video(candidate_id)
    insert_placement(placement_id, customer_id)
    insert_match(placement_id, candidate_id, "suggested")

    assert {:ok, video} =
             DirectVideos.show_candidate_video(customer_id, placement_id, candidate_id)

    assert video["candidateUserId"] == candidate_id
    assert video["introVideoUrl"] == "https://media.example.com/intro.mp4"

    assert {:error, :not_found} =
             DirectVideos.show_candidate_video(other_customer_id, placement_id, candidate_id)
  end

  test "customer cannot read a video after the match is rejected" do
    customer_id = Ecto.UUID.generate()
    candidate_id = Ecto.UUID.generate()
    placement_id = Ecto.UUID.generate()

    insert_user(customer_id)
    insert_candidate(candidate_id)
    insert_video(candidate_id)
    insert_placement(placement_id, customer_id)
    insert_match(placement_id, candidate_id, "rejected")

    assert {:error, :not_found} =
             DirectVideos.show_candidate_video(customer_id, placement_id, candidate_id)
  end

  test "customer video access follows placement and match lifecycle states" do
    customer_id = Ecto.UUID.generate()
    candidate_id = Ecto.UUID.generate()
    cancelled_placement_id = Ecto.UUID.generate()
    placed_placement_id = Ecto.UUID.generate()

    insert_user(customer_id)
    insert_candidate(candidate_id)
    insert_video(candidate_id)

    insert_placement(cancelled_placement_id, customer_id, "cancelled")
    insert_match(cancelled_placement_id, candidate_id, "suggested")

    assert {:error, :not_found} =
             DirectVideos.show_candidate_video(
               customer_id,
               cancelled_placement_id,
               candidate_id
             )

    insert_placement(placed_placement_id, customer_id, "placed")
    insert_match(placed_placement_id, candidate_id, "hired")

    assert {:ok, _video} =
             DirectVideos.show_candidate_video(customer_id, placed_placement_id, candidate_id)
  end

  test "admin can attach, read, and clear a vetted candidate video" do
    admin_id = Ecto.UUID.generate()
    candidate_id = Ecto.UUID.generate()

    insert_user(admin_id)
    insert_candidate(candidate_id)
    grant_role(admin_id, "admin")

    params = %{
      "introVideoUrl" => "https://media.example.com/intro.mp4",
      "introVideoThumbnailUrl" => "https://media.example.com/intro.jpg",
      "introVideoTitle" => "Meet Ama"
    }

    assert {:ok, saved} =
             DirectVideos.update_admin_candidate_video(admin_id, candidate_id, params)

    assert saved["introVideoTitle"] == "Meet Ama"

    assert {:ok, current} =
             DirectVideos.show_admin_candidate_video(admin_id, candidate_id)

    assert current["introVideoUrl"] == "https://media.example.com/intro.mp4"

    assert {:ok, cleared} =
             DirectVideos.update_admin_candidate_video(admin_id, candidate_id, %{
               "introVideoUrl" => nil,
               "introVideoThumbnailUrl" => nil,
               "introVideoTitle" => nil
             })

    assert cleared["introVideoUrl"] == nil
  end

  test "reviewers can read and update vetted candidate videos" do
    reviewer_id = Ecto.UUID.generate()
    candidate_id = Ecto.UUID.generate()

    insert_user(reviewer_id)
    insert_candidate(candidate_id)
    grant_role(reviewer_id, "reviewer")

    assert {:ok, saved} =
             DirectVideos.update_admin_candidate_video(reviewer_id, candidate_id, %{
               "introVideoUrl" => "https://media.example.com/reviewer-intro.mp4",
               "introVideoThumbnailUrl" => nil,
               "introVideoTitle" => "Reviewed intro"
             })

    assert saved["introVideoTitle"] == "Reviewed intro"

    assert {:ok, current} =
             DirectVideos.show_admin_candidate_video(reviewer_id, candidate_id)

    assert current["introVideoUrl"] == "https://media.example.com/reviewer-intro.mp4"
  end

  test "video updates reject non-HTTPS URLs and non-staff users" do
    admin_id = Ecto.UUID.generate()
    customer_id = Ecto.UUID.generate()
    candidate_id = Ecto.UUID.generate()

    insert_user(admin_id)
    insert_user(customer_id)
    insert_candidate(candidate_id)
    grant_role(admin_id, "admin")

    assert {:error, :invalid_video_url} =
             DirectVideos.update_admin_candidate_video(admin_id, candidate_id, %{
               "introVideoUrl" => "http://media.example.com/intro.mp4"
             })

    assert {:error, :forbidden} =
             DirectVideos.update_admin_candidate_video(customer_id, candidate_id, %{
               "introVideoUrl" => "https://media.example.com/intro.mp4"
             })
  end

  test "video title length uses PostgreSQL character semantics" do
    admin_id = Ecto.UUID.generate()
    candidate_id = Ecto.UUID.generate()

    insert_user(admin_id)
    insert_candidate(candidate_id)
    grant_role(admin_id, "admin")

    decomposed_title = String.duplicate("e\u0301", 120)

    assert String.length(decomposed_title) == 120
    assert length(String.to_charlist(decomposed_title)) == 240

    assert {:error, :video_title_too_long} =
             DirectVideos.update_admin_candidate_video(admin_id, candidate_id, %{
               "introVideoUrl" => "https://media.example.com/intro.mp4",
               "introVideoTitle" => decomposed_title
             })
  end

  defp insert_user(id) do
    Repo.query!("INSERT INTO public.users (id, email) VALUES ($1, $2)", [
      Ecto.UUID.dump!(id),
      "user@example.com"
    ])
  end

  defp insert_candidate(id) do
    insert_user(id)

    Repo.query!(
      "INSERT INTO public.cleaner_data (user_id, verified, status) VALUES ($1, true, 'active')",
      [Ecto.UUID.dump!(id)]
    )
  end

  defp insert_video(candidate_id) do
    Repo.query!(
      """
      INSERT INTO public.placement_candidate_profiles (
        user_id,
        intro_video_url,
        intro_video_thumbnail_url,
        intro_video_title
      ) VALUES ($1, $2, $3, $4)
      """,
      [
        Ecto.UUID.dump!(candidate_id),
        "https://media.example.com/intro.mp4",
        "https://media.example.com/intro.jpg",
        "Meet this helper"
      ]
    )
  end

  defp insert_placement(id, customer_id, status \\ "shortlisted") do
    Repo.query!(
      "INSERT INTO public.placement_requests (id, customer_id, status) VALUES ($1, $2, $3)",
      [Ecto.UUID.dump!(id), Ecto.UUID.dump!(customer_id), status]
    )
  end

  defp insert_match(placement_id, candidate_id, status) do
    Repo.query!(
      """
      INSERT INTO public.placement_matches (
        id,
        placement_request_id,
        candidate_user_id,
        status
      ) VALUES ($1, $2, $3, $4)
      """,
      [
        Ecto.UUID.dump!(Ecto.UUID.generate()),
        Ecto.UUID.dump!(placement_id),
        Ecto.UUID.dump!(candidate_id),
        status
      ]
    )
  end

  defp grant_role(user_id, role) do
    Repo.query!("INSERT INTO public.user_roles (user_id, role_id) VALUES ($1, $2)", [
      Ecto.UUID.dump!(user_id),
      role
    ])
  end
end
