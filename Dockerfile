# Ubuntu-on-Web (Render) — Full project

This single-file project bundle contains a minimal full-stack system you can deploy to Render (or any Docker host) to let users pick and create an **Ubuntu Desktop** or **Ubuntu Server** instance from a web UI. The backend talks to Docker and spawns prebuilt container images (one with noVNC for desktop, one minimal for server) and returns the container's public access information (IP/port). The frontend shows two buttons (1. Desktop, 2. Server), shows install progress, and then shows the public access URL (IPv4:port).

> **Files included (in this doc):**
> - `docker-compose.yml` — local dev orchestration.
> - `backend/Dockerfile` + `backend/index.js` — Express API that uses `dockerode` to create/manage containers.
> - `backend/package.json` — backend deps.
> - `frontend/src/App.jsx` — React UI (single-file component) and `frontend/package.json` + `frontend/Dockerfile`.
> - `README.md` — quick deployment instructions for Render.

---

## Important safety & operational notes

1. **Security**: Exposing interactive desktops or SSH terminals publicly is potentially dangerous. This example is _not_ production-hardened. Add authentication, per-user isolation, usage limits, logging, and resource quotas before opening to the public.
2. **Host capabilities**: The backend needs access to Docker on the host (mount `/var/run/docker.sock`) or run as a host that can create containers. On Render you must enable "Docker" and use a single Dockerfile that runs the backend and mounts the socket (if Render supports it) — otherwise use a host with Docker access (self-host or cloud VM).
3. **Images used**: To keep things simple we reference well-known community images:
   - Desktop: `dorowu/ubuntu-desktop-lxde-vnc` (contains LXDE + noVNC server already set up).
   - Server: `ubuntu:24.04` plus a tiny `gotty` or SSH server install done at container start.

---

### `docker-compose.yml`

```yaml
version: '3.8'
services:
  backend:
    build: ./backend
    restart: unless-stopped
    ports:
      - '3000:3000' # API
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock # backend talks to host docker
  frontend:
    build: ./frontend
    restart: unless-stopped
    ports:
      - '80:80'
```

---

### `backend/Dockerfile`

```dockerfile
FROM node:20-slim
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci
COPY . .
EXPOSE 3000
CMD ["node","index.js"]
```

### `backend/package.json`

```json
{
  "name": "ubuntu-spawner-backend",
  "version": "1.0.0",
  "main": "index.js",
  "dependencies": {
    "express": "^4.18.2",
    "dockerode": "^3.3.0",
    "uuid": "^9.0.0"
  }
}
```

### `backend/index.js`

```js
const express = require('express');
const Docker = require('dockerode');
const { v4: uuidv4 } = require('uuid');
const docker = new Docker({socketPath: '/var/run/docker.sock'});
const app = express();
app.use(express.json());

// In-memory store for simplicity
const tasks = {};

app.post('/deploy', async (req, res) => {
  const { type } = req.body; // 'desktop' or 'server'
  if (!['desktop','server'].includes(type)) return res.status(400).json({error:'type must be desktop or server'});
  const id = uuidv4();
  tasks[id] = { status: 'queued', type };

  (async () => {
    try {
      tasks[id].status = 'pulling';
      const image = type === 'desktop' ? 'dorowu/ubuntu-desktop-lxde-vnc:latest' : 'ubuntu:24.04';
      // pull image if missing
      await new Promise((resolve,reject)=>{
        docker.pull(image, (err, stream)=>{
          if (err) return reject(err);
          docker.modem.followProgress(stream, onFinished, onProgress);
          function onFinished(err, output){ if (err) reject(err); else resolve(output); }
          function onProgress(ev) { /* optional: could push logs to tasks[id].progress */ }
        });
      });

      tasks[id].status = 'creating';

      // Port mapping: choose a random host port
      const hostPort = await getFreePort();

      // container create config
      let createOptions;
      if (type === 'desktop') {
        // dorowu image exposes 6080 for noVNC
        createOptions = {
          Image: image,
          name: `ubuntu_desktop_${id}`,
          ExposedPorts: { '6080/tcp': {} },
          HostConfig: {
            PortBindings: { '6080/tcp': [{ HostPort: String(hostPort) }] },
            // limit resources if desired
            AutoRemove: false
          }
        };
      } else {
        // server: create and run a tiny gotty server inside; we'll use command to install 'python3 -m http.server' as simple shell
        createOptions = {
          Image: image,
          name: `ubuntu_server_${id}`,
          Cmd: ['/bin/bash','-lc',"apt update && apt install -y curl openssh-server && mkdir /var/run/sshd && echo 'root:ubuntu' | chpasswd && sed -i 's/PermitRootLogin prohibit-password/PermitRootLogin yes/' /etc/ssh/sshd_config && service ssh start && tail -f /dev/null"],
          ExposedPorts: { '22/tcp': {} },
          HostConfig: { PortBindings: { '22/tcp': [{ HostPort: String(hostPort) }] }, AutoRemove: false }
        };
      }

      const container = await docker.createContainer(createOptions);
      tasks[id].status = 'starting';
      await container.start();

      // Wait a little for services to start (not ideal but simple)
      await new Promise(r=>setTimeout(r,6000));

      tasks[id].status = 'running';
      tasks[id].containerId = container.id;
      tasks[id].hostPort = hostPort;

    } catch (err) {
      console.error(err);
      tasks[id].status = 'error';
      tasks[id].error = err.message;
    }
  })();

  res.json({ id });
});

app.get('/status/:id', (req,res)=>{
  const id = req.params.id;
  const t = tasks[id];
  if (!t) return res.status(404).json({error:'task not found'});
  return res.json(t);
});

// Helper: pick a free port on host (simple approach: random within range, assume available). In production use port allocator.
async function getFreePort(){
  const min = 30000, max = 40000;
  for (let i=0;i<100;i++){
    const p = Math.floor(Math.random()*(max-min))+min;
    // naive: try to bind a server to check
    const net = require('net');
    const server = net.createServer();
    try{
      await new Promise((resolve,reject)=>server.once('error',reject).once('listening',resolve).listen(p, '0.0.0.0'));
      server.close();
      return p;
    }catch(e){ /* in use */ }
  }
  throw new Error('no free ports');
}

app.listen(3000, ()=>console.log('API listening on 3000'));
```

---

### `frontend/src/App.jsx` (single-file React app)

```jsx
import React, {useState} from 'react';

export default function App(){
  const [id, setId] = useState(null);
  const [status, setStatus] = useState(null);
  const [type, setType] = useState(null);

  async function deploy(kind){
    setType(kind);
    const r = await fetch('/api/deploy', { method: 'POST', headers: {'Content-Type':'application/json'}, body: JSON.stringify({type:kind}) });
    const j = await r.json();
    if (j.id){ setId(j.id); setStatus({status:'queued'}); pollStatus(j.id); }
  }

  async function pollStatus(taskId){
    const intv = setInterval(async ()=>{
      const r = await fetch(`/api/status/${taskId}`);
      const j = await r.json();
      setStatus(j);
      if (j && (j.status === 'running' || j.status === 'error')) clearInterval(intv);
    }, 2000);
  }

  return (
    <div style={{fontFamily:'system-ui',padding:24}}>
      <h1>Ubuntu on Web</h1>
      <p>Chọn một: </p>
      <div>
        <button onClick={()=>deploy('desktop')}>1. Ubuntu Desktop (noVNC)</button>
        <button onClick={()=>deploy('server')} style={{marginLeft:12}}>2. Ubuntu Server (SSH)</button>
      </div>

      {status && <div style={{marginTop:20}}>
        <h3>Trạng thái: {status.status}</h3>
        {status.status === 'running' && (
          <div>
            <p>Loại: {status.type}</p>
            <p>Host port: {status.hostPort}</p>
            <p>Truy cập: <a target="_blank" rel="noreferrer" href={getAccessUrl(status)}>{getAccessUrl(status)}</a></p>
            <p>Ghi chú: Nếu là Desktop -> noVNC (web). Nếu Server -> SSH on port.</p>
          </div>
        )}
        {status.status === 'error' && <pre>{status.error}</pre>}
      </div>}
    </div>
  );
}

function getAccessUrl(status){
  // For Render or remote host you must replace 'HOST_IP' with actual host public IP or domain.
  // When running on same machine, 'localhost' will work.
  const host = window.location.hostname; // best-effort
  const port = status.hostPort;
  if (status.type === 'desktop') return `http://${host}:${port}`; // noVNC served on 6080 container
  return `ssh://root@${host}:${port}`;
}
```

---

### Frontend `Dockerfile` (for static build served by nginx)

```dockerfile
FROM node:20-alpine as build
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci
COPY . .
RUN npm run build

FROM nginx:stable-alpine
COPY --from=build /app/build /usr/share/nginx/html
EXPOSE 80
CMD ["nginx","-g","daemon off;"]
```

---

### README (deployment summary)

1. Build & run locally with docker-compose (for testing):
   - `docker compose up --build`
   - Visit `http://localhost` for the web UI and `http://localhost:3000` for API.

2. To deploy to Render:
   - Push the repo to GitHub.
   - Create a Render **Web Service** for the backend. Use the `backend/Dockerfile` and make sure to give it access to Docker socket if you want it to control Docker on the host (Render may not allow this). Alternatively deploy to a VM or a cloud host where you control Docker.
   - Create another Web Service for the frontend (or serve frontend from the backend via a static route).

3. After deployment the web UI will let visitors click "Desktop" or "Server". The backend creates a container and binds the appropriate container port to a public host port — the UI will show `http://<your-host-ip>:<port>` or `ssh://root@<your-host-ip>:<port>`.

---

## Final notes

This repository is intentionally minimal to show the flow. Before using in production, please:
- Add authentication and authorization.
- Add container lifetime & cleanup logic.
- Use a proper port allocator and avoid random host port collisions.
- Harden container images and secrets (don't use root/no password in production).


---

Good luck! Open the code file in this canvas — everything's included in separate sections. If you want, I can now:
- convert this into a GitHub-ready repo (zip) and provide a download link, or
- harden the backend with authentication and cleanup logic, or
- switch the desktop image to a different prebuilt image you prefer.

Tell me which next step and I'll update the canvas accordingly.
