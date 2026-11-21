yt-dlp \
    -f "bestaudio/best" \
    -x \
    --audio-format flac \
    --audio-quality 0 \
    --embed-metadata \
    --embed-thumbnail \
    --convert-thumbnails jpg \
    --parse-metadata "playlist_index:%(track_number)s" \
    --windows-filenames \
    -o "%(uploader)s - %(title)s.%(ext)s" \
    "https://www.youtube.com/watch?v=ALq6X-OucWI"
