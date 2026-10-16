package com.zjx.usblinkmic.platform
import android.Manifest
import android.app.Service
import android.content.Intent
import android.content.pm.PackageManager
import android.media.*
import android.os.IBinder
import com.zjx.usblinkmic.contracts.*
import org.json.JSONObject
import java.io.DataOutputStream
import java.net.InetSocketAddress
import java.net.Socket
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.concurrent.thread
import kotlin.math.sqrt

class MicrophoneService : Service() {
 companion object {
  @Volatile var recording=false
  @Volatile private var recorder: AudioRecord?=null
  @Volatile private var socket: Socket?=null
  fun stopCapture(){recording=false;try{recorder?.stop()}catch(_:IllegalStateException){};try{socket?.close()}catch(_:Exception){}}
 }
 private var request: Request?=null
 override fun onBind(intent: Intent?): IBinder?=null
 override fun onStartCommand(intent: Intent?,flags:Int,startId:Int):Int {
  if(intent?.action=="STOP"){Runtime.audioRequest?.let{it.cancelled=true};stopCapture();stopSelf();return START_NOT_STICKY}
  val r=Runtime.audioRequest
  if(r==null || r.cancelled || !r.accepted || intent?.getStringExtra("session")!=r.session){stopSelf();return START_NOT_STICKY}
  request=r
  if(checkSelfPermission(Manifest.permission.RECORD_AUDIO)!=PackageManager.PERMISSION_GRANTED){Runtime.fail(r,"MICROPHONE_DENIED");stopSelf();return START_NOT_STICKY}
  startForeground(10,Notifications.create(this,"USB LinkMic正在采音",Intent(this,MicrophoneService::class.java).setAction("STOP")))
  thread(name="linkmic-capture") {capture(r)}
  return START_NOT_STICKY
 }
 private fun capture(r:Request) {
  var ownedRecorder:AudioRecord?=null;var ownedSocket:Socket?=null
  try {
   val p=r.settings.audio
   require(Runtime.parametersSupported(p)){"UNSUPPORTED_AUDIO"}
   val encoding=if(p.format==PCMFormat.I16)AudioFormat.ENCODING_PCM_16BIT else AudioFormat.ENCODING_PCM_FLOAT
   val mask=if(p.channels==1)AudioFormat.CHANNEL_IN_MONO else AudioFormat.CHANNEL_IN_STEREO
   val min=AudioRecord.getMinBufferSize(p.sampleRate,mask,encoding)
   if(p.source==RecordingSource.UNPROCESSED){val manager=getSystemService(AudioManager::class.java);require(manager.getProperty(AudioManager.PROPERTY_SUPPORT_AUDIO_SOURCE_UNPROCESSED)=="true"){"UNSUPPORTED_SOURCE"}}
   if(checkSelfPermission(Manifest.permission.RECORD_AUDIO)!=PackageManager.PERMISSION_GRANTED) throw SecurityException("MICROPHONE_DENIED")
   val audio=AudioRecord.Builder().setAudioSource(Runtime.source(p)).setAudioFormat(AudioFormat.Builder().setEncoding(encoding).setSampleRate(p.sampleRate).setChannelMask(mask).build()).setBufferSizeInBytes(maxOf(min*2,8192)).build()
   ownedRecorder=audio;recorder=audio
   check(audio.state==AudioRecord.STATE_INITIALIZED && audio.sampleRate==p.sampleRate && audio.channelCount==p.channels && audio.audioFormat==encoding){"AUDIO_HARDWARE_UNAVAILABLE_OR_FORMAT_CHANGED"}
   val connection=Socket();ownedSocket=connection;socket=connection
   connection.connect(InetSocketAddress(if(r.mode=="wifi")r.settings.wifiHost else "127.0.0.1",r.settings.audioPort),10000);connection.soTimeout=10000
   val out=DataOutputStream(connection.getOutputStream())
   val header=JSONObject().put("protocol",4).put("session",r.session).put("token",r.token).put("sampleRate",p.sampleRate).put("channels",p.channels).put("format",if(p.format==PCMFormat.I16)"i16" else "f32").put("source",when(p.source){RecordingSource.MICROPHONE->"microphone";RecordingSource.UNPROCESSED->"unprocessed";else->"voiceRecognition"})
   out.write((header.toString()+"\n").toByteArray());out.flush()
   val reply=connection.getInputStream().bufferedReader().readLine();check(JSONObject(reply).optBoolean("accepted")){"HANDSHAKE_REJECTED"}
   if(r.cancelled || Runtime.audioRequest !== r) return
   audio.startRecording();check(audio.recordingState==AudioRecord.RECORDSTATE_RECORDING){"AUDIO_HARDWARE_BUSY"};recording=true
   Runtime.update{it.copy(microphone=ModuleStatus(TaskPhase.RUNNING,"正在采音","静音不代表停止录音"),effectiveAudio=p,controlledByMac=r.mode=="audio")}
   val count=1024*p.channels;val shorts=ShortArray(count);val floats=FloatArray(count)
   while(!r.cancelled && Runtime.audioRequest===r && recording){
    val n=if(p.format==PCMFormat.I16)audio.read(shorts,0,count,AudioRecord.READ_BLOCKING) else audio.read(floats,0,count,AudioRecord.READ_BLOCKING)
    check(n>0){"AUDIO_READ_FAILED:$n"}
    check(n%p.channels==0){"BAD_FRAME_ALIGNMENT"}
    val bytes=ByteBuffer.allocate(n*(if(p.format==PCMFormat.I16)2 else 4)).order(ByteOrder.LITTLE_ENDIAN)
    var energy=0.0;val trend=ArrayList<Double>()
    for(i in 0 until n){val v=if(p.format==PCMFormat.I16)shorts[i].toDouble()/32768 else floats[i].toDouble();check(v.isFinite()){ "BAD_SAMPLE" };if(p.format==PCMFormat.I16)bytes.putShort(shorts[i]) else bytes.putFloat(floats[i]);energy+=v*v;if(i%maxOf(1,n/64)==0 && trend.size<64)trend.add(v)}
    out.writeInt(bytes.position());out.write(bytes.array());out.flush()
    val level=sqrt(energy/n)
    Runtime.update{it.copy(level=level,waveform=trend,frames=it.frames+1)}
   }
  }catch(e:Exception){if(!r.cancelled)Runtime.fail(r,e.message ?: e.javaClass.simpleName)}
  finally{try{ownedRecorder?.stop()}catch(_:Exception){};ownedRecorder?.release();try{ownedSocket?.close()}catch(_:Exception){};if(Runtime.audioRequest===r){recording=false;recorder=null;socket=null};stopSelf()}
 }
 override fun onDestroy(){request?.cancelled=true;stopCapture();if(Runtime.audioRequest===request)Runtime.audioRequest=null;Runtime.update{if(it.microphone.phase==TaskPhase.FAILED)it.copy(level=0.0,waveform=emptyList()) else it.copy(microphone=ModuleStatus(),level=0.0,waveform=emptyList())};super.onDestroy()}
}
