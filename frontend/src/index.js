import React,{useState} from 'react';
export default function App(){
 const [link,setLink]=useState("");
 async function create(t){
  const r=await fetch("http://localhost:3000/create",{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify({type:t})});
  const d=await r.json();
  if(d.ok) setLink("http://YOUR-IP:"+d.port);
 }
 return <div style={{padding:20}}>
  <button onClick={()=>create("desktop")}>Desktop</button>
  <button onClick={()=>create("server")}>Server</button>
  <div>{link}</div>
 </div>;
}
