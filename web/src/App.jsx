import { useCallback, useEffect, useMemo, useRef, useState } from 'react';

const API_BASE = (import.meta.env.VITE_API_BASE || '').replace(/\/$/, '');
const STATUS_INTERVAL_MS = 5000;

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

function Empty({ children }) {
  return <div className="empty">{children}</div>;
}

function VideoCard({ file, onDelete, onPlaybackChange, onPlaybackError }) {
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
    <article className="card">
      <video
        ref={videoRef}
        preload="none"
        poster={serverAsset(file.thumbUrl)}
        controls
        playsInline
        onPointerDownCapture={loadMedia}
        onPlay={() => {
          loadMedia();
          onPlaybackChange(file.id, true);
        }}
        onPause={() => onPlaybackChange(file.id, false)}
        onEnded={() => onPlaybackChange(file.id, false)}
      />
      <div className="meta">
        <div className="title" title={file.name}>{file.name}</div>
        <div className="subtle">{file.sizeText} · {file.mtime}</div>
        <div className="row">
          <button className="btn2" type="button" onClick={play}>播放</button>
          <button className="btn2" type="button" onClick={() => onDelete(file.id)}>删除</button>
        </div>
      </div>
    </article>
  );
}

function TaskItem({ task, onDelete }) {
  return (
    <div className="task">
      <div className="row">
        <b className="task-title" title={task.name}>{task.name}</b>
        <button className="btn2" type="button" onClick={() => onDelete(task.id)}>移除</button>
      </div>
      <div className="task-line">
        {taskStateText(task.state)} · {task.downloadedText} / {task.lengthText} · {task.downloadSpeedText} · {task.peers} 连接
      </div>
      {task.error ? <div className="bad">{task.error}</div> : null}
      <div className="bar">
        <div className="fill" style={{ width: percent(task.progress) }} />
      </div>
    </div>
  );
}

export default function App() {
  const [accessKey, setAccessKey] = useState('');
  const [magnet, setMagnet] = useState('');
  const [message, setMessage] = useState({ text: '', bad: false });
  const [status, setStatus] = useState(null);
  const [files, setFiles] = useState([]);
  const [tasks, setTasks] = useState([]);

  const fileSigRef = useRef('');
  const pendingFilesRef = useRef(null);
  const playingIdsRef = useRef(new Set());

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

  const space = status?.space || {};
  const visitors = status?.visitors || {};

  return (
    <main className="page">
      <header className="header">
        <h1>月光放映室</h1>
        <div className="subtle">本周访客 <b>{visitors.weeklyVisitors ?? '—'}</b></div>
      </header>

      <section className="panel">
        <div className="form">
          <input
            className="input"
            value={magnet}
            onChange={(event) => setMagnet(event.target.value)}
            onKeyDown={(event) => {
              if (event.key === 'Enter') addMagnet();
            }}
            placeholder="粘贴 magnet 磁力链接"
          />
          <button className="btn" type="button" onClick={addMagnet}>开始下载</button>
        </div>

        <input
          className="input key-input"
          value={accessKey}
          onChange={(event) => setAccessKey(event.target.value)}
          placeholder="访问密钥：下载、移除任务、删除影片时需要"
        />

        <div className="stats">
          <div className="stat">
            <span>已用空间</span>
            <b>{space.usedText || '—'} / {space.totalText || '—'}</b>
            <div className="bar"><div className="fill" style={{ width: percent(space.usedPct) }} /></div>
          </div>
          <div className="stat"><span>可用空间</span><b>{space.availableText || '—'}</b></div>
          <div className="stat"><span>片库占用</span><b>{space.libraryText || '—'}</b></div>
          <div className="stat"><span>任务限制</span><b>{status ? `${status.maxActive} 下载 / ${status.maxQueued} 排队` : '—'}</b></div>
          <div className="stat"><span>Tracker</span><b>{status?.trackers ?? '—'}</b></div>
        </div>

        <div className={message.bad ? 'message bad' : 'message'}>{message.text}</div>
      </section>

      <section className="layout">
        <section>
          <h2>影片</h2>
          <div className="grid">
            {files.length ? files.map((file) => (
              <VideoCard
                key={file.id}
                file={file}
                onDelete={deleteFile}
                onPlaybackChange={handlePlaybackChange}
                onPlaybackError={(text) => showMessage(text, true)}
              />
            )) : <Empty>暂无影片。</Empty>}
          </div>
        </section>

        <aside>
          <h2>任务</h2>
          {tasks.length ? tasks.map((task) => (
            <TaskItem key={task.id} task={task} onDelete={deleteTask} />
          )) : <Empty>暂无任务。</Empty>}
        </aside>
      </section>
    </main>
  );
}
