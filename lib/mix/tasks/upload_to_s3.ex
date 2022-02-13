defmodule Mix.Tasks.UploadToS3 do
  use Mix.Task

  alias Philomena.{
    Adverts.Advert,
    Badges.Badge,
    Images.Image,
    Tags.Tag,
    Users.User
  }

  alias Philomena.Images.Thumbnailer
  alias Philomena.Mime
  alias Philomena.Batch
  alias ExAws.S3
  import Ecto.Query

  @shortdoc "Dumps existing image files to S3 storage backend"
  @requirements ["app.start"]
  @impl Mix.Task
  def run([concurrency | args]) do
    {concurrency, _} = Integer.parse(concurrency)

    if Enum.member?(args, "--adverts") do
      file_root = System.get_env("OLD_ADVERT_FILE_ROOT", "priv/static/system/images/adverts")
      new_file_root = Application.fetch_env!(:philomena, :advert_file_root)

      IO.puts "\nAdverts:"
      upload_typical(where(Advert, [a], not is_nil(a.image)), concurrency, file_root, new_file_root, :image)
    end

    if Enum.member?(args, "--avatars") do
      file_root = System.get_env("OLD_AVATAR_FILE_ROOT", "priv/static/system/images/avatars")
      new_file_root = Application.fetch_env!(:philomena, :avatar_file_root)

      IO.puts "\nAvatars:"
      upload_typical(where(User, [u], not is_nil(u.avatar)), concurrency, file_root, new_file_root, :avatar)
    end

    if Enum.member?(args, "--badges") do
      file_root = System.get_env("OLD_BADGE_FILE_ROOT", "priv/static/system/images")
      new_file_root = Application.fetch_env!(:philomena, :badge_file_root)

      IO.puts "\nBadges:"
      upload_typical(where(Badge, [b], not is_nil(b.image)), concurrency, file_root, new_file_root, :image)
    end

    if Enum.member?(args, "--tags") do
      file_root = System.get_env("OLD_TAG_FILE_ROOT", "priv/static/system/images")
      new_file_root = Application.fetch_env!(:philomena, :tag_file_root)

      IO.puts "\nTags:"
      upload_typical(where(Tag, [t], not is_nil(t.image)), concurrency, file_root, new_file_root, :image)
    end

    if Enum.member?(args, "--images") do
      file_root = Path.join(System.get_env("OLD_IMAGE_FILE_ROOT", "priv/static/system/images"), "thumbs")
      new_file_root = Application.fetch_env!(:philomena, :image_file_root)

      # Temporarily set file root to empty path so we can get the proper prefix
      Application.put_env(:philomena, :image_file_root, "")

      IO.puts "\nImages:"
      upload_images(where(Image, [i], not is_nil(i.image)), concurrency, file_root, new_file_root)
    end
  end

  defp upload_typical(queryable, batch_size, file_root, new_file_root, field_name) do
    Batch.record_batches(queryable, [batch_size: batch_size], fn models ->
      models
      |> Task.async_stream(&upload_typical_model(&1, file_root, new_file_root, field_name))
      |> Stream.run()

      IO.write "\r#{hd(models).id}"
    end)
  end

  defp upload_typical_model(model, file_root, new_file_root, field_name) do
    field = Map.fetch!(model, field_name)
    path = Path.join(file_root, field)

    if File.regular?(path) do
      put_file(path, Path.join(new_file_root, field))
    end
  end

  defp upload_images(queryable, batch_size, file_root, new_file_root) do
    Batch.record_batches(queryable, [batch_size: batch_size], fn models ->
      models
      |> Task.async_stream(&upload_image_model(&1, file_root, new_file_root))
      |> Stream.run()

      IO.write "\r#{hd(models).id}"
    end)
  end

  defp upload_image_model(model, file_root, new_file_root) do
    path_prefix = Thumbnailer.image_thumb_prefix(model)

    Thumbnailer.all_versions(model)
    |> Enum.map(fn version ->
      path = Path.join([file_root, path_prefix, version])
      new_path = Path.join([new_file_root, path_prefix, version])

      if File.regular?(path) do
        put_file(path, new_path)
      end
    end)
  end

  defp put_file(path, uploaded_path) do
    {_, mime} = Mime.file(path)
    contents = File.read!(path)

    S3.put_object(bucket(), uploaded_path, contents, acl: :public_read, content_type: mime)
    |> ExAws.request!()
  end

  defp bucket do
    Application.fetch_env!(:philomena, :s3_bucket)
  end
end
