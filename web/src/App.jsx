import { useCallback, useEffect, useMemo, useRef, useState } from 'react';

const API_BASE = (import.meta.env.VITE_API_BASE || '').replace(/\/$/, '');
const STATUS_INTERVAL_MS = 5000;
const KEY_STORAGE = 'moonroom.accessKey';
const RECENT_STORAGE = 'moonroom.recentFiles';
const PROGRESS_STORAGE = 'moonroom.playProgress';

function apiPath(path) {
  return `${API_BASE}${path}`;
}

function serverAsset(url) {
  const value = String(url || '');
  if (!value || /^(https?:)?\/\//i.test(value) || value.startsWith('data:')) return value;

  // 后端返回的 /media 和 /thumb 默认是同域相对地址。
  // 如果用户把 dist 上传到独立静态站点，可在构建时设置 VITE_API_BASE，
  // 这里会同步把视频与封面请求指回脚本 API 域名。
  return `${API_BASE}${value.startsWith('/') ? value : `/${value}`}`;
}

function readLocal(key, fallback) {
  try {
    const value = window.localStorage.getItem(key);
    return value ? JSON.parse(value) : fallback;
  } catch {
    return fallback;
  }
}

function writeLocal(key, value) {
  try {
    window.localStorage.setItem(key, JSON.stringify(value));
  } catch {}
}

async function readJson(response) {
  const text = await response.text();
  if (!text) return {};

  try {
    return JSON.parse(text);
  } catch {
    throw new Error(text || `HTTP ${response.status}`);
  }
}

async function requestJson(path, options = {}) {
  const response = await fetch(apiPath(path), {
    cache: 'no-store',
    ...options,
  });
  const data = await readJson(response);

  if (!response.ok || data.ok === false) {
    throw new Error(data.error || `HTTP ${response.status}`);
  }

  return data;
}

function percent(value) {
  return `${Math.max(0, Math.min(100, Number(value) || 0))}%`;
}

function fileSignature(files) {
  return files.map((file) => `${file.id}|${file.size}|${file.mtime}`).join('||');
}

function taskStateText(state) {
  return {
    downloading: '下载中',
    queued: '排队中',
    failed: '失败',
    done: '完成',
  }[state] || state || '未知';
}

function progressLabel(saved) {
  if (!saved?.duration || !saved?.time) return '';
  return `${Math.round((saved.time / saved.duration) * 100)}%`;
}

function sortFiles(files, sortMode, recentIds) {
  const recentRank = new Map(recentIds.map((id, index) => [id, index]));
  const next = [...files];
  if (sortMode === 'name') return next.sort((a, b) => a.name.localeCompare(b.name, 'zh-CN', { numeric: true }));
  if (sortMode === 'size') return next.sort((a, b) => Number(b.size || 0) - Number(a.size || 0));
  if (sortMode === 'recent') {
    return next.sort((a, b) => {
      const ar = recentRank.has(a.id) ? recentRank.get(a.id) : 9999;
      const br = recentRank.has(b.id) ? recentRank.get(b.id) : 9999;
      return ar - br || Number(b.mtimeMs || 0) - Number(a.mtimeMs || 0);
    });
  }
  return next.sort((a, b) => Number(b.mtimeMs || 0) - Number(a.mtimeMs || 0));
}

function Empty({ children }) {
  return <div className="empty">{children}</div>;
}

function Stat({ label, value, detail }) {
  return (
    <div className="stat">
      <span>{label}</span>
      <b>{value}</b>
      {detail ? <em>{detail}</em> : null}
    </div>
  );
}

function VideoCard({ file, savedProgress, isRecent, onDelete, onPlayed, onPlaybackChange, onPlaybackError, onProgress }) {
  const videoRef = useRef(null);
  const loadedRef = useRef(false);

  const loadMedia = useCallback(() => {
    const video = videoRef.current;
    if (!video || loadedRef.current) return video;

    // 关键点：React 首屏只渲染 poster，不渲染 src/source。
    // 只有用户点击播放按钮或视频控件时才把真实 /media 地址挂到 video 上，
    // 这样访问页面、刷新任务、查看片库都不会提前触发视频 Range 请求。
    video.src = serverAsset(file.url);
    video.load();
    loadedRef.current = true;
    return video;
  }, [file.url]);

  const play = useCallback(async () => {
    const video = loadMedia();
    if (!video) return;

    try {
      await video.play();
    } catch {
      onPlaybackError('浏览器无法播放该格式');
    }
  }, [loadMedia, onPlaybackError]);

  return (
    <article className="video-card">
      <div className="poster-shell">
        <video
          ref={videoRef}
          preload="none"
          poster={serverAsset(file.thumbUrl)}
          controls
          playsInline
          onLoadedMetadata={(event) => {
            if (savedProgress?.time && savedProgress.time < event.currentTarget.duration - 8) {
              event.currentTarget.currentTime = savedProgress.time;
            }
          }}
          onPointerDownCapture={loadMedia}
          onPlay={() => {
            loadMedia();
            onPlayed(file.id);
            onPlaybackChange(file.id, true);
          }}
          onPause={() => onPlaybackChange(file.id, false)}
          onEnded={() => onPlaybackChange(file.id, false)}
          onTimeUpdate={(event) => onProgress(file.id, event.currentTarget.currentTime, event.currentTarget.duration)}
        />
        <button className="play-float" type="button" onClick={play}>播放</button>
        {isRecent ? <span className="badge">最近</span> : null}
      </div>

      <div className="meta">
        <div className="title" title={file.name}>{file.name}</div>
        <div className="subtle">{file.sizeText} · {file.mtime}</div>
        <div className="card-actions">
          <span>{progressLabel(savedProgress) || file.type}</span>
          <button className="ghost-btn danger-btn" type="button" onClick={() => onDelete(file.id)}>删除</button>
        </div>
      </div>
    </article>
  );
}

function TaskItem({ task, onDelete }) {
  const isBad = task.state === 'failed';

  return (
    <div className={isBad ? 'task task-bad' : 'task'}>
      <div className="task-head">
        <b className="task-title" title={task.name}>{task.name}</b>
        <button className="ghost-btn" type="button" onClick={() => onDelete(task.id)}>移除</button>
      </div>
      <div className="task-line">
        {taskStateText(task.state)} · {task.downloadedText} / {task.lengthText}
      </div>
      <div className="task-line">{task.downloadSpeedText} · {task.peers} 连接</div>
      {task.error ? <div className="bad">{task.error}</div> : null}
      <div className="bar">
        <div className="fill" style={{ width: percent(task.progress) }} />
      </div>
    </div>
  );
}

export default function App() {
  const [accessKey, setAccessKey] = useState(() => readLocal(KEY_STORAGE, ''));
  const [magnet, setMagnet] = useState('');
  const [message, setMessage] = useState({ text: '', bad: false });
  const [status, setStatus] = useState(null);
  const [files, setFiles] = useState([]);
  const [tasks, setTasks] = useState([]);
  const [query, setQuery] = useState('');
  const [sortMode, setSortMode] = useState('latest');
  const [recentIds, setRecentIds] = useState(() => readLocal(RECENT_STORAGE, []));
  const [progressMap, setProgressMap] = useState(() => readLocal(PROGRESS_STORAGE, {}));

  const fileSigRef = useRef('');
  const pendingFilesRef = useRef(null);
  const playingIdsRef = useRef(new Set());
  const progressWriteRef = useRef(0);

  useEffect(() => {
    if (accessKey.trim()) writeLocal(KEY_STORAGE, accessKey);
    else {
      try {
        window.localStorage.removeItem(KEY_STORAGE);
      } catch {}
    }
  }, [accessKey]);

  const authHeaders = useMemo(() => {
    const key = accessKey.trim();
    return key ? { 'X-Library-Key': key } : {};
  }, [accessKey]);

  const showMessage = useCallback((text, bad = false) => {
    setMessage({ text: text || '', bad });
  }, []);

  const applyFiles = useCallback((nextFiles, force = false) => {
    const nextSig = fileSignature(nextFiles);
    if (!force && nextSig === fileSigRef.current) return;

    // 下载完成会让片库列表发生变化。旧版页面每次轮询都 innerHTML 重建，
    // 正在播放的视频会被销毁；这里把“播放中收到的新片库”先暂存，
    // 等全部视频暂停/结束后再应用，保证播放不会被任务完成打断。
    if (!force && playingIdsRef.current.size > 0) {
      pendingFilesRef.current = nextFiles;
      return;
    }

    fileSigRef.current = nextSig;
    pendingFilesRef.current = null;
    setFiles(nextFiles);
  }, []);

  const flushPendingFiles = useCallback(() => {
    if (playingIdsRef.current.size > 0 || !pendingFilesRef.current) return;

    const nextFiles = pendingFilesRef.current;
    pendingFilesRef.current = null;
    fileSigRef.current = fileSignature(nextFiles);
    setFiles(nextFiles);
  }, []);

  const refreshStatus = useCallback(async (forceFiles = false) => {
    const data = await requestJson('/api/status');
    setStatus(data);
    setTasks(data.torrents || []);
    applyFiles(data.files || [], forceFiles);

    if (!data.downloadEnabled) {
      showMessage(`下载器不可用：${data.downloadError}`, true);
    }
  }, [applyFiles, showMessage]);

  useEffect(() => {
    let alive = true;

    async function tick() {
      try {
        const data = await requestJson('/api/status');
        if (!alive) return;
        setStatus(data);
        setTasks(data.torrents || []);
        applyFiles(data.files || []);

        if (!data.downloadEnabled) {
          showMessage(`下载器不可用：${data.downloadError}`, true);
        }
      } catch (error) {
        if (alive) showMessage(`状态刷新失败：${error.message}`, true);
      }
    }

    tick();
    const timer = setInterval(() => {
      tick();
      flushPendingFiles();
    }, STATUS_INTERVAL_MS);

    return () => {
      alive = false;
      clearInterval(timer);
    };
  }, [applyFiles, flushPendingFiles, showMessage]);

  const addMagnet = useCallback(async () => {
    const value = magnet.trim();
    if (!value) {
      showMessage('请粘贴磁力链接', true);
      return;
    }

    try {
      showMessage('正在创建任务...');
      await requestJson('/api/downloads', {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          ...authHeaders,
        },
        body: JSON.stringify({ magnet: value }),
      });
      setMagnet('');
      showMessage('任务已创建');
      await refreshStatus();
    } catch (error) {
      showMessage(error.message || '创建失败', true);
    }
  }, [authHeaders, magnet, refreshStatus, showMessage]);

  const deleteTask = useCallback(async (id) => {
    try {
      await requestJson(`/api/downloads/${encodeURIComponent(id)}`, {
        method: 'DELETE',
        headers: authHeaders,
      });
      await refreshStatus();
    } catch (error) {
      showMessage(error.message || '移除失败', true);
    }
  }, [authHeaders, refreshStatus, showMessage]);

  const deleteFile = useCallback(async (id) => {
    if (!window.confirm('确认删除这个影片文件？')) return;

    try {
      await requestJson(`/api/files/${encodeURIComponent(id)}`, {
        method: 'DELETE',
        headers: authHeaders,
      });
      await refreshStatus(true);
    } catch (error) {
      showMessage(error.message || '删除失败', true);
    }
  }, [authHeaders, refreshStatus, showMessage]);

  const handlePlaybackChange = useCallback((id, playing) => {
    if (playing) {
      playingIdsRef.current.add(id);
      return;
    }

    playingIdsRef.current.delete(id);
    flushPendingFiles();
  }, [flushPendingFiles]);

  const handlePlayed = useCallback((id) => {
    setRecentIds((old) => {
      const next = [id, ...old.filter((item) => item !== id)].slice(0, 16);
      writeLocal(RECENT_STORAGE, next);
      return next;
    });
  }, []);

  const handleProgress = useCallback((id, time, duration) => {
    if (!Number.isFinite(time) || !Number.isFinite(duration) || duration <= 0) return;
    const now = Date.now();
    if (now - progressWriteRef.current < 1500) return;
    progressWriteRef.current = now;

    setProgressMap((old) => {
      const next = { ...old, [id]: { time, duration, updatedAt: now } };
      writeLocal(PROGRESS_STORAGE, next);
      return next;
    });
  }, []);

  const clearLocalHistory = useCallback(() => {
    setRecentIds([]);
    setProgressMap({});
    writeLocal(RECENT_STORAGE, []);
    writeLocal(PROGRESS_STORAGE, {});
  }, []);

  const visibleFiles = useMemo(() => {
    const needle = query.trim().toLowerCase();
    const filtered = needle
      ? files.filter((file) => `${file.name} ${file.rel || ''}`.toLowerCase().includes(needle))
      : files;
    return sortFiles(filtered, sortMode, recentIds);
  }, [files, query, recentIds, sortMode]);

  const space = status?.space || {};
  const visitors = status?.visitors || {};
  const summary = status?.summary || {};
  const activeTasks = summary.downloadingCount ?? tasks.filter((task) => task.state === 'downloading').length;
  const queuedTasks = summary.queuedCount ?? tasks.filter((task) => task.state === 'queued').length;
  const failedTasks = summary.failedCount ?? tasks.filter((task) => task.state === 'failed').length;
  const totalSpeed = summary.totalDownloadSpeedText || '0 B/s';

  return (
    <main className="page">
      <header className="topbar">
        <a className="brand" href="#library" aria-label="Moonroom">
          <span className="brand-mark">M</span>
          <span>
            <strong>Moonroom</strong>
            <small>Private Cinema</small>
          </span>
        </a>
        <nav className="nav">
          <a href="#library">片库</a>
          <a href="#tasks">任务</a>
          <a href="https://hanime1.me/" target="_blank" rel="noopener noreferrer">Hanime</a>
        </nav>
        <div className="visitor-pill">本周 {visitors.weeklyVisitors ?? '—'}</div>
      </header>

      <section className="hero-panel">
        <div className="hero-copy">
          <p>Moonroom</p>
          <h1>月光放映室</h1>
        </div>

        <div className="command-panel">
          <div className="magnet-row">
            <input
              className="input magnet-input"
              value={magnet}
              onChange={(event) => setMagnet(event.target.value)}
              onKeyDown={(event) => {
                if (event.key === 'Enter') addMagnet();
              }}
              placeholder="magnet:?xt=urn:btih:..."
            />
            <button className="primary-btn" type="button" onClick={addMagnet}>开始下载</button>
          </div>
          <div className="key-row">
            <input
              className="input"
              type="password"
              value={accessKey}
              onChange={(event) => setAccessKey(event.target.value)}
              placeholder="访问密钥"
            />
            <div className={message.bad ? 'message bad' : 'message'}>{message.text || '状态就绪'}</div>
          </div>
        </div>
      </section>

      <section className="stats">
        <Stat label="影片" value={summary.fileCount ?? files.length} detail={space.libraryText || '—'} />
        <Stat label="任务" value={`${activeTasks} / ${queuedTasks}`} detail={`${failedTasks} 失败`} />
        <Stat label="速度" value={totalSpeed} detail={`${status?.trackers ?? '—'} tracker`} />
        <div className="stat">
          <span>空间</span>
          <b>{space.availableText || '—'}</b>
          <em>{space.usedText || '—'} / {space.totalText || '—'}</em>
          <div className="bar"><div className="fill" style={{ width: percent(space.usedPct) }} /></div>
        </div>
      </section>

      <section className="app-layout">
        <section className="library" id="library">
          <div className="section-head">
            <div>
              <p>Library</p>
              <h2>片库</h2>
            </div>
            <div className="tools">
              <input
                className="input search-input"
                value={query}
                onChange={(event) => setQuery(event.target.value)}
                placeholder="搜索片名"
              />
              <select className="select" value={sortMode} onChange={(event) => setSortMode(event.target.value)}>
                <option value="latest">最新</option>
                <option value="recent">最近播放</option>
                <option value="name">名称</option>
                <option value="size">大小</option>
              </select>
            </div>
          </div>

          <div className="grid">
            {visibleFiles.length ? visibleFiles.map((file) => (
              <VideoCard
                key={file.id}
                file={file}
                savedProgress={progressMap[file.id]}
                isRecent={recentIds.includes(file.id)}
                onDelete={deleteFile}
                onPlayed={handlePlayed}
                onPlaybackChange={handlePlaybackChange}
                onPlaybackError={(text) => showMessage(text, true)}
                onProgress={handleProgress}
              />
            )) : <Empty>暂无影片。</Empty>}
          </div>
        </section>

        <aside className="side-rail" id="tasks">
          <section className="rail-section">
            <div className="rail-head">
              <h2>任务</h2>
              <span>{tasks.length}</span>
            </div>
            {tasks.length ? tasks.map((task) => (
              <TaskItem key={task.id} task={task} onDelete={deleteTask} />
            )) : <Empty>暂无任务。</Empty>}
          </section>

          <section className="rail-section">
            <div className="rail-head">
              <h2>记录</h2>
              <button className="ghost-btn" type="button" onClick={clearLocalHistory}>清空</button>
            </div>
            {recentIds.length ? recentIds.slice(0, 5).map((id) => {
              const file = files.find((item) => item.id === id);
              return (
                <div className="recent-item" key={id}>
                  <span>{file?.name || id.slice(0, 10)}</span>
                  <b>{progressLabel(progressMap[id]) || '—'}</b>
                </div>
              );
            }) : <Empty>暂无记录。</Empty>}
          </section>
        </aside>
      </section>
    </main>
  );
}
