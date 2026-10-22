#!/usr/bin/env python3
"""Loopback-only Emby protocol fixture. Requires ffmpeg with libass; never a real Emby server."""
import argparse
import json
import mimetypes
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import subprocess
import threading
import time
from urllib.parse import parse_qs, urlsplit
import uuid

ROOT = Path(__file__).resolve().parent.parent / ".local" / "smoke"
LOCK = threading.Lock()
POSITIONS = {}
FAVORITES = set()
TOKEN = "muxi-local-test-token"


def media(item_id="movie"):
    names = {"movie": "幕汐播放测试", "mkv": "幕汐 MKV 轨道测试", "show": "幕汐测试剧集", "season": "第 1 季"}
    wall_index = int(item_id.removeprefix("wall-")) if item_id.startswith("wall-") else None
    kind = "Movie" if item_id in ("movie", "mkv") or wall_index is not None else {"show": "Series", "season": "Season"}.get(item_id, "Episode")
    name = names.get(item_id, f"潮汐片场 {wall_index:02d}" if wall_index is not None else "测试剧集 · 第一集")
    position = POSITIONS.get(item_id, 120_000_000 if item_id in ("movie", "mkv") or kind == "Episode" else 0)
    return {"Id": item_id, "Name": name, "Type": kind, "IsFolder": kind in ("Series", "Season"),
            "RunTimeTicks": 900_000_000, "ProductionYear": 2026, "Overview": "本机生成的测试视频，用于验证真实解码、双音轨、字幕、画质切换和进度同步。不是远程 Emby 内容。",
            "Genres": ["动画" if wall_index is not None and wall_index % 2 else "剧情"],
            "ProductionLocations": ["日本" if wall_index is not None and wall_index % 2 else "中国"] if wall_index != 67 else [],
            "CommunityRating": 10.0 if wall_index == 0 else round(6 + ((wall_index or 0) % 30) / 10, 1),
            "DateCreated": f"2026-10-{(wall_index or 0) % 28 + 1:02d}T10:00:00Z",
            "UserData": {"PlaybackPositionTicks": position, "PlayedPercentage": position / 9_000_000,
                         "Played": wall_index == 0, "IsFavorite": item_id in FAVORITES}, "ImageTags": {}}


def library_items(query):
    parent = query.get("ParentId", [""])[0]
    movies = [media(), media("mkv"), *(media(f"wall-{index:02d}") for index in range(68))]
    if parent == "show":
        items = [media("season")] if query.get("Recursive") == ["false"] else [media("season"), media("episode")]
    elif parent == "season":
        items = [media("episode")]
    elif parent == "series":
        items = [media("show")]
    elif parent in ("films", "broken"):
        items = movies
    else:
        items = movies + [media("show"), media("episode")]
    types = set(query.get("IncludeItemTypes", [""])[0].split(",")) - {""}
    if types:
        items = [item for item in items if item["Type"] in types]
    term = query.get("SearchTerm", [""])[0].casefold()
    items = [item for item in items if term in item["Name"].casefold()]
    filters = query.get("Filters", [""])[0].split(",")
    if "IsFavorite" in filters:
        items = [item for item in items if item["UserData"]["IsFavorite"]]
    if "IsUnplayed" in filters:
        items = [item for item in items if not item["UserData"]["Played"]]
    keys = query.get("SortBy", ["SortName"])[0].split(",")
    items.sort(key=lambda item: tuple(item.get("Name" if key == "SortName" else key, 0) for key in keys),
               reverse=query.get("SortOrder") == ["Descending"])
    total = len(items)
    start = max(0, int(query.get("StartIndex", ["0"])[0]))
    if parent == "broken":
        start = 0
    # Deliberately cap index pages to verify clients handle server-imposed page sizes.
    limit = min(60, max(0, int(query.get("Limit", ["60"])[0])))
    return {"Items": items[start:start + limit], "TotalRecordCount": total}


def run_ffmpeg(args):
    subprocess.run([FFMPEG, "-hide_banner", "-loglevel", "error", "-nostdin", "-y", *args], check=True)


def prepare():
    ROOT.mkdir(parents=True, exist_ok=True)
    (ROOT / "zh.srt").write_text("1\n00:00:00,000 --> 00:01:30,000\n幕汐字幕测试：山海之间，自在观看。\n", encoding="utf8")
    (ROOT / "en.srt").write_text("1\n00:00:00,000 --> 00:01:30,000\nMuxi subtitle test: your library, your cinema.\n", encoding="utf8")
    (ROOT / "external.srt").write_text("1\n00:00:00,000 --> 00:01:30,000\nExternal subtitle: loaded independently of the video stream.\n", encoding="utf8")
    if not (ROOT / "source.mp4").exists():
        run_ffmpeg(["-f", "lavfi", "-i", "testsrc2=size=1280x720:rate=24", "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000",
                    "-f", "lavfi", "-i", "sine=frequency=880:sample_rate=48000", "-t", "90", "-map", "0:v", "-map", "1:a", "-map", "2:a",
                    "-c:v", "libx264", "-preset", "ultrafast", "-crf", "26", "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "96k",
                    "-metadata:s:a:0", "language=zho", "-metadata:s:a:1", "language=eng", "-movflags", "+faststart", str(ROOT / "source.mp4")])
    if not (ROOT / "source.mkv").exists():
        run_ffmpeg(["-i", str(ROOT / "source.mp4"), "-i", str(ROOT / "zh.srt"), "-i", str(ROOT / "en.srt"),
                    "-map", "0", "-map", "1:s", "-map", "2:s", "-c", "copy",
                    "-metadata:s:s:0", "language=zho", "-metadata:s:s:0", "title=简体中文",
                    "-metadata:s:s:1", "language=eng", "-metadata:s:s:1", "title=English",
                    str(ROOT / "source.mkv")])


def source(item_id, direct=True):
    value = {"Id": "source", "Name": "MKV 原始版本" if item_id == "mkv" else "MP4 原始版本",
             "Container": "mkv" if item_id == "mkv" else "mp4", "Bitrate": 8_000_000,
             "SupportsDirectPlay": direct, "SupportsDirectStream": False, "SupportsTranscoding": not direct,
             "DefaultAudioStreamIndex": 1, "RunTimeTicks": 900_000_000,
             "MediaStreams": [{"Index": 0, "Type": "Video", "Codec": "h264", "Height": 720, "Width": 1280},
                              {"Index": 1, "Type": "Audio", "DisplayTitle": "中文 · AAC · 440 Hz", "Codec": "aac", "Language": "zho", "Channels": 1},
                              {"Index": 2, "Type": "Audio", "DisplayTitle": "English · AAC · 880 Hz", "Codec": "aac", "Language": "eng", "Channels": 1},
                              {"Index": 3, "Type": "Subtitle", "DisplayTitle": "简体中文 · SRT", "Codec": "srt", "Language": "zho"},
                              {"Index": 4, "Type": "Subtitle", "DisplayTitle": "English · SRT", "Codec": "srt", "Language": "eng"}]}
    if item_id == "mkv":
        value["MediaStreams"].append({"Index": 5, "Type": "Subtitle", "DisplayTitle": "English · 外部 SRT", "Codec": "srt",
                                      "Language": "eng", "IsExternal": True, "DeliveryMethod": "External",
                                      "DeliveryUrl": "/emby/media/external.srt", "DeliveryFormat": "srt"})
    else:
        for track, filename in zip(value["MediaStreams"][3:], ("zh.srt", "en.srt")):
            track.update(IsExternal=True, DeliveryMethod="External", DeliveryUrl=f"/emby/media/{filename}", DeliveryFormat="srt")
    return value


def transcode(body):
    profile = body["DeviceProfile"]["TranscodingProfiles"][0]
    height = min(int(profile.get("MaxHeight", 720)), 720)
    bitrate = min(int(body["MaxStreamingBitrate"]), 8_000_000)
    audio = int(body.get("AudioStreamIndex", 1))
    subtitle = int(body.get("SubtitleStreamIndex", -1))
    assert height in (480, 720) and audio in (1, 2) and subtitle in (-1, 3, 4)
    key = f"h{height}-b{bitrate}-a{audio}-s{subtitle}"
    directory = ROOT / key
    with LOCK:
        if not (directory / "index.m3u8").exists():
            directory.mkdir(exist_ok=True)
            filters = f"scale=-2:{height}"
            if subtitle >= 0:
                filters += f",subtitles={ROOT / ('zh.srt' if subtitle == 3 else 'en.srt')}:force_style='Fontsize=24'"
            run_ffmpeg(["-i", str(ROOT / "source.mp4"), "-map", "0:v:0", "-map", f"0:a:{audio - 1}", "-vf", filters,
                        "-c:v", "libx264", "-preset", "ultrafast", "-b:v", str(bitrate), "-maxrate", str(bitrate), "-bufsize", str(bitrate * 2),
                        "-g", "48", "-sc_threshold", "0", "-c:a", "aac", "-b:a", "96k", "-f", "hls", "-hls_time", "2",
                        "-hls_playlist_type", "vod", "-hls_segment_filename", str(directory / "seg%03d.ts"), str(directory / "index.m3u8")])
    return key


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def respond(self, value, status=200):
        data = json.dumps(value).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def parsed(self):
        value = urlsplit(self.path)
        return value.path.removeprefix("/emby"), parse_qs(value.query)

    def authorized(self, query):
        return (self.headers.get("X-Emby-Token") == TOKEN or query.get("api_key") == [TOKEN]
                or f'Token="{TOKEN}"' in self.headers.get("Authorization", ""))

    def do_POST(self):
        path, query = self.parsed()
        body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))) or "{}")
        if path == "/Users/AuthenticateByName":
            if body.get("Username") != "demo" or body.get("Pw") != "demo":
                return self.respond({}, 401)
            return self.respond({"AccessToken": TOKEN, "User": {"Id": "user", "Name": "本机测试"}, "ServerId": "muxi-fixture"})
        if not self.authorized(query):
            return self.respond({}, 401)
        if path.startswith("/Users/user/FavoriteItems/"):
            item_id = path.rsplit("/", 1)[-1]
            with LOCK:
                FAVORITES.add(item_id)
            self.record("Favorite", {"item": item_id, "value": True})
            return self.respond(media(item_id)["UserData"])
        if path.endswith("PlaybackInfo"):
            item_id = path.split("/")[-2]
            direct = body.get("EnableDirectPlay", False) or not body.get("IsPlayback", True)
            key = None if direct else transcode(body)
            selected_source = source(item_id, direct)
            if key:
                selected_source["TranscodingUrl"] = f"/emby/media/{key}/index.m3u8"
            self.record("PlaybackInfo", {"height": body["DeviceProfile"]["TranscodingProfiles"][0].get("MaxHeight", 0),
                                         "bitrate": body["MaxStreamingBitrate"], "audio": body.get("AudioStreamIndex"), "subtitle": body.get("SubtitleStreamIndex", -1),
                                         "isPlayback": body.get("IsPlayback", True), "item": item_id})
            return self.respond({"PlaySessionId": uuid.uuid4().hex, "MediaSources": [selected_source]})
        if path.startswith("/Sessions/Playing"):
            if 'DeviceId="report-failure"' in self.headers.get("Authorization", ""):
                return self.respond({}, 503)
            POSITIONS[body["ItemId"]] = body["PositionTicks"]
            self.record(path, {key: body.get(key) for key in ["PositionTicks", "PlaySessionId", "IsPaused", "PlayMethod", "AudioStreamIndex", "SubtitleStreamIndex"]})
        return self.respond({})

    def do_GET(self):
        path, query = self.parsed()
        if path.startswith("/media/") or path.startswith("/Videos/"):
            relative = ("source.mkv" if path.split("/")[2] == "mkv" else "source.mp4") if path.startswith("/Videos/") else path.removeprefix("/media/")
            return self.send_file(relative, slow=path.startswith("/Videos/slow/"))
        if not self.authorized(query):
            return self.respond({}, 401)
        if path.endswith("/Views"):
            items = [{"Id": "films", "Name": "本机测试片库", "Type": "CollectionFolder", "IsFolder": True},
                     {"Id": "series", "Name": "本机测试剧集", "Type": "CollectionFolder", "IsFolder": True}]
        elif path.endswith("/Resume"):
            items = [media()]
        elif path.endswith("/Items"):
            return self.respond(library_items(query))
        else:
            return self.respond(media(path.rsplit("/", 1)[-1]))
        self.respond({"Items": items, "TotalRecordCount": len(items)})

    def do_DELETE(self):
        path, query = self.parsed()
        if not self.authorized(query):
            return self.respond({}, 401)
        if path.startswith("/Users/user/FavoriteItems/"):
            item_id = path.rsplit("/", 1)[-1]
            with LOCK:
                FAVORITES.discard(item_id)
            self.record("Favorite", {"item": item_id, "value": False})
            return self.respond(media(item_id)["UserData"])
        self.record(path, {"PlaySessionId": query.get("PlaySessionId", [None])[0]})
        self.respond({})

    def send_file(self, relative, slow=False):
        file = (ROOT / relative).resolve()
        if not file.is_relative_to(ROOT.resolve()) or not file.is_file():
            return self.respond({}, 404)
        size = file.stat().st_size
        start, end = 0, size - 1
        partial = self.headers.get("Range")
        if partial:
            first, last = partial.removeprefix("bytes=").split("-", 1)
            start, end = int(first or 0), min(int(last) if last else end, end)
        self.send_response(206 if partial else 200)
        self.send_header("Content-Type", "application/vnd.apple.mpegurl" if file.suffix == ".m3u8" else "video/mp2t" if file.suffix == ".ts" else mimetypes.guess_type(file.name)[0] or "application/octet-stream")
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("Content-Length", str(end - start + 1))
        if partial:
            self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
        self.end_headers()
        sent = 0
        try:
            with file.open("rb") as stream:
                stream.seek(start)
                remaining = end - start + 1
                while remaining > 0:
                    data = stream.read(min(remaining, 65536))
                    if not data:
                        break
                    self.wfile.write(data)
                    sent += len(data)
                    remaining -= len(data)
                    if slow:
                        time.sleep(0.03)
        except (BrokenPipeError, ConnectionResetError):
            pass
        finally:
            if slow:
                self.record("StreamClosed", {"bytes": sent, "complete": sent == end - start + 1})

    def record(self, event, values):
        with LOCK, (ROOT / "events.jsonl").open("a") as stream:
            stream.write(json.dumps({"event": event, **values}) + "\n")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", type=int, default=18796)
    parser.add_argument("--ffmpeg", default="ffmpeg")
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    FFMPEG = args.ffmpeg
    if args.self_test:
        assert media()["UserData"]["PlaybackPositionTicks"] == 120_000_000
        assert media("episode")["Type"] == "Episode"
        assert media("mkv")["Type"] == "Movie"
        assert source("movie")["Container"] == "mp4"
        assert source("movie")["MediaStreams"][3]["IsExternal"] is True
        assert source("mkv")["MediaStreams"][-1]["IsExternal"] is True
        assert [track["Index"] for track in source("mkv")["MediaStreams"]] == list(range(6))
        page = library_items({"IncludeItemTypes": ["Movie"], "Limit": ["60"]})
        assert len(page["Items"]) == 60 and page["TotalRecordCount"] == 70
        tail = library_items({"IncludeItemTypes": ["Movie"], "StartIndex": ["60"]})
        assert len(tail["Items"]) == 10
        assert not {item["Id"] for item in page["Items"]} & {item["Id"] for item in tail["Items"]}
        recommended = library_items({"IncludeItemTypes": ["Movie"], "Filters": ["IsUnplayed"], "SortBy": ["CommunityRating"], "SortOrder": ["Descending"]})["Items"]
        assert all(not item["UserData"]["Played"] for item in recommended)
        assert recommended[0]["CommunityRating"] >= recommended[-1]["CommunityRating"]
        assert library_items({"SearchTerm": ["mkv"]})["Items"][0]["Id"] == "mkv"
        assert library_items({"ParentId": ["series"]})["Items"][0]["Id"] == "show"
        assert library_items({"Filters": ["IsFavorite"]})["Items"] == []
        FAVORITES.add("movie")
        assert library_items({"Filters": ["IsFavorite"]})["Items"][0]["Id"] == "movie"
        FAVORITES.discard("movie")
        assert not (ROOT / "../outside").resolve().is_relative_to(ROOT.resolve())
        print("Fixture checks passed")
    else:
        prepare()
        print(f"Local fixture: http://127.0.0.1:{args.port}/emby — demo / demo", flush=True)
        ThreadingHTTPServer(("127.0.0.1", args.port), Handler).serve_forever()
