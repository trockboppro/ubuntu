const express=require('express');
const Docker=require('dockerode');
const cors=require('cors');
const app=express();
app.use(cors());
app.use(express.json());
const docker=new Docker();

app.post('/create', async (req,res)=>{
 const type=req.body.type;
 let image = type==="desktop" ? "dorowu/ubuntu-desktop-lxde-vnc" : "ubuntu:22.04";
 let port = type==="desktop" ? 6080 : 22;
 try{
   const container = await docker.createContainer({
     Image:image,
     Tty:true,
     ExposedPorts:{ [port+"/tcp"]:{} },
     HostConfig:{ PortBindings:{ [port+"/tcp"]:[{ HostPort:"0" }] } }
   });
   await container.start();
   const data=await container.inspect();
   const hostPort=data.NetworkSettings.Ports[port+"/tcp"][0].HostPort;
   res.json({ ok:true, port:hostPort });
 } catch(e){ res.json({ ok:false, error:e.toString() }); }
});

app.listen(3000,()=>console.log("backend ok"));
