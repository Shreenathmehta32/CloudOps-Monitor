fetch("status.json")

.then(response=>response.json())

.then(data=>{

document.getElementById("hostname").innerHTML=data.hostname;

document.getElementById("user").innerHTML=data.user;

document.getElementById("date").innerHTML=data.date;

document.getElementById("uptime").innerHTML=data.uptime;

document.getElementById("memory").innerHTML=data.memory;

document.getElementById("disk").innerHTML=data.disk;

});
