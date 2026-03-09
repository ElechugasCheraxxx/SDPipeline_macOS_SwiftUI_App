import SwiftUI
import WebKit

// MARK: - Sheet wrapper

struct ModelBuilderSheet: View {
    var onUse: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var webView: WKWebView?

    var body: some View {
        VStack(spacing: 0) {

            // ── Toolbar ──────────────────────────────────────────────
            HStack(spacing: 10) {
                HStack(spacing: 8) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(
                                LinearGradient(
                                    colors: [Color(hex: "#7c6af7"), Color(hex: "#3de3c0")],
                                    startPoint: .topLeading, endPoint: .bottomTrailing
                                )
                            )
                            .frame(width: 24, height: 24)
                        Text("AI")
                            .font(.system(size: 9, weight: .black))
                            .foregroundColor(.white)
                    }
                    Text("AI Model Builder")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(.white.opacity(0.85))
                    Text("EDITORIAL V1")
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundColor(Color(hex: "#7c6af7"))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color(hex: "#7c6af7").opacity(0.15))
                        .clipShape(Capsule())
                        .overlay(Capsule().stroke(Color(hex: "#7c6af7").opacity(0.35), lineWidth: 1))
                }
                Spacer()

                // "→ Usar en pipeline" — calls JS then dismisses
                Button(action: sendJSON) {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.right.circle.fill")
                            .font(.system(size: 13))
                        Text("Usar en Pipeline")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(Color(hex: "#7c6af7"))
                    .foregroundColor(.white)
                    .cornerRadius(8)
                }
                .buttonStyle(.plain)

                Button(action: { dismiss() }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.secondary)
                        .padding(7)
                        .background(Color.white.opacity(0.07))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(Color(red: 0.07, green: 0.07, blue: 0.1))

            Divider().background(Color.white.opacity(0.08))

            // ── WebView ──────────────────────────────────────────────
            ModelBuilderWebView(onJSONReady: { json in
                onUse(json)
                dismiss()
            }, webViewRef: $webView)
        }
        .frame(width: 1160, height: 720)
        .background(Color(red: 0.04, green: 0.04, blue: 0.07))
    }

    private func sendJSON() {
        webView?.evaluateJavaScript("JSON.stringify(buildJSON(),null,2)") { result, _ in
            if let json = result as? String {
                DispatchQueue.main.async {
                    onUse(json)
                    dismiss()
                }
            }
        }
    }
}

// MARK: - NSViewRepresentable

struct ModelBuilderWebView: NSViewRepresentable {
    var onJSONReady: (String) -> Void
    @Binding var webViewRef: WKWebView?

    func makeNSView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.userContentController.add(context.coordinator, name: "jsonReady")

        let wv = WKWebView(frame: .zero, configuration: cfg)
        wv.loadHTMLString(ModelBuilderHTML.source, baseURL: nil)

        DispatchQueue.main.async { webViewRef = wv }
        return wv
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onJSONReady: onJSONReady)
    }

    class Coordinator: NSObject, WKScriptMessageHandler {
        let onJSONReady: (String) -> Void
        init(onJSONReady: @escaping (String) -> Void) { self.onJSONReady = onJSONReady }

        func userContentController(_ ucc: WKUserContentController, didReceive msg: WKScriptMessage) {
            guard msg.name == "jsonReady", let json = msg.body as? String else { return }
            DispatchQueue.main.async { self.onJSONReady(json) }
        }
    }
}

// Color(hex:) → Color+Hex.swift

// MARK: - Embedded HTML

enum ModelBuilderHTML {
    static let source: String = """
<!DOCTYPE html>
<html lang="es">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>AI Model Builder</title>
<link href="https://fonts.googleapis.com/css2?family=Syne:wght@400;600;700;800&family=JetBrains+Mono:wght@300;400;500&display=swap" rel="stylesheet">
<style>
:root{--bg:#0a0a0f;--sur:#111118;--sur2:#18181f;--brd:#2a2a38;--acc:#7c6af7;--acc2:#3de3c0;--acc3:#f7a76a;--txt:#e8e8f0;--dim:#6b6b88;--mid:#9999b8;--red:#f76a6a}
*,*::before,*::after{box-sizing:border-box;margin:0;padding:0}
body{font-family:'Syne',sans-serif;background:var(--bg);color:var(--txt);height:100vh;overflow:hidden;display:flex;flex-direction:column}
.main{display:grid;grid-template-columns:370px 1fr;flex:1;overflow:hidden}
.lp{background:var(--sur);border-right:1px solid var(--brd);display:flex;flex-direction:column;overflow:hidden}
.tabs{display:flex;overflow-x:auto;border-bottom:1px solid var(--brd);flex-shrink:0;scrollbar-width:none;padding:0 2px}
.tabs::-webkit-scrollbar{display:none}
.tb{font-family:'Syne',sans-serif;font-size:10px;font-weight:600;padding:11px 12px;background:none;border:none;color:var(--dim);cursor:pointer;white-space:nowrap;border-bottom:2px solid transparent;transition:all .15s;letter-spacing:.04em}
.tb:hover{color:var(--txt)}.tb.on{color:var(--acc);border-bottom-color:var(--acc)}
.fa{flex:1;overflow-y:auto;padding:18px;scrollbar-width:thin;scrollbar-color:var(--brd) transparent}
.tc{display:none}.tc.on{display:block}
.f{margin-bottom:16px}
.fl{display:flex;align-items:center;justify-content:space-between;margin-bottom:5px}
label{font-size:10px;font-weight:600;color:var(--mid);letter-spacing:.06em;text-transform:uppercase}
.fv{font-family:'JetBrains Mono',monospace;font-size:10px;color:var(--acc2)}
input[type=text],select,textarea{width:100%;background:var(--sur2);border:1px solid var(--brd);border-radius:6px;padding:8px 11px;color:var(--txt);font-family:'JetBrains Mono',monospace;font-size:11px;transition:border-color .15s;outline:none}
input:focus,select:focus,textarea:focus{border-color:var(--acc);box-shadow:0 0 0 3px rgba(124,106,247,.1)}
select option{background:#1a1a25}
textarea{resize:vertical;min-height:58px}
input[type=range]{-webkit-appearance:none;width:100%;height:4px;background:var(--brd);border-radius:4px;outline:none;border:none;padding:0;cursor:pointer}
input[type=range]::-webkit-slider-thumb{-webkit-appearance:none;width:15px;height:15px;background:var(--acc);border-radius:50%;border:2px solid var(--bg);box-shadow:0 0 0 1px var(--acc);transition:transform .1s}
input[type=range]::-webkit-slider-thumb:hover{transform:scale(1.25)}
.tg{display:flex;gap:6px;flex-wrap:wrap}
.to{font-size:10px;font-weight:600;padding:4px 11px;border-radius:20px;border:1px solid var(--brd);background:transparent;color:var(--dim);cursor:pointer;transition:all .15s;font-family:'Syne',sans-serif;letter-spacing:.04em}
.to:hover{border-color:var(--acc);color:var(--txt)}.to.s{background:rgba(124,106,247,.15);border-color:var(--acc);color:var(--acc)}
.sr{display:flex;align-items:center;justify-content:space-between;padding:7px 0;border-bottom:1px solid var(--brd)}
.sr:last-child{border-bottom:none}
.sl{font-size:11px;color:var(--txt)}
.sw{width:34px;height:19px;background:var(--brd);border-radius:20px;position:relative;cursor:pointer;transition:background .2s;flex-shrink:0}
.sw.on{background:var(--acc)}
.sw::after{content:'';position:absolute;width:13px;height:13px;background:#fff;border-radius:50%;top:3px;left:3px;transition:transform .2s}
.sw.on::after{transform:translateX(15px)}
.st{font-size:9px;font-weight:700;letter-spacing:.1em;text-transform:uppercase;color:var(--acc3);margin:20px 0 10px;display:flex;align-items:center;gap:8px}
.st::after{content:'';flex:1;height:1px;background:linear-gradient(to right,var(--brd),transparent)}
.rp{display:flex;flex-direction:column;overflow:hidden;background:#060610}
.ch{display:flex;align-items:center;justify-content:space-between;padding:9px 18px;background:var(--sur);border-bottom:1px solid var(--brd);flex-shrink:0}
.chl{display:flex;align-items:center;gap:10px}
.dot{width:9px;height:9px;border-radius:50%}
.dr{background:#ff5f57}.dy{background:#febc2e}.dg{background:#28c840}
.fn{font-family:'JetBrains Mono',monospace;font-size:10px;color:var(--dim);letter-spacing:.04em}
.live{display:flex;align-items:center;gap:5px;font-size:9px;font-weight:600;color:var(--acc2);letter-spacing:.08em}
.ld{width:6px;height:6px;border-radius:50%;background:var(--acc2);animation:pulse 1.5s ease-in-out infinite}
@keyframes pulse{0%,100%{opacity:1;transform:scale(1)}50%{opacity:.4;transform:scale(.6)}}
.co{flex:1;overflow-y:auto;padding:20px 24px;font-family:'JetBrains Mono',monospace;font-size:12px;line-height:1.75;scrollbar-width:thin;scrollbar-color:var(--brd) transparent;white-space:pre}
.jk{color:#8bc4f8}.js{color:#a8e8a8}.jn{color:#ffd08a}.jt{color:#3de3c0}.jf{color:#f76a6a}.jnu{color:#555570}
.use-btn{font-family:'Syne',sans-serif;font-size:11px;font-weight:700;padding:6px 16px;border-radius:7px;border:none;cursor:pointer;letter-spacing:.04em;background:linear-gradient(135deg,var(--acc),var(--acc2));color:#fff;transition:all .2s}
.use-btn:hover{transform:translateY(-1px);box-shadow:0 4px 16px rgba(124,106,247,.4)}
::-webkit-scrollbar{width:3px;height:3px}::-webkit-scrollbar-track{background:transparent}::-webkit-scrollbar-thumb{background:var(--brd);border-radius:4px}
</style>
</head>
<body>
<div class="main">
  <div class="lp">
    <div class="tabs" id="tabs"></div>
    <div class="fa" id="forms"></div>
  </div>
  <div class="rp">
    <div class="ch">
      <div class="chl">
        <div style="display:flex;gap:5px"><div class="dot dr"></div><div class="dot dy"></div><div class="dot dg"></div></div>
        <span class="fn">ai_model_schema.json</span>
      </div>
      <div style="display:flex;align-items:center;gap:10px">
        <div class="live"><div class="ld"></div>LIVE</div>
        <button class="use-btn" onclick="sendToNative()">→ Usar en Pipeline</button>
      </div>
    </div>
    <div class="co" id="out"></div>
  </div>
</div>
<script>
const S={gender:'',body_type:'',smile:'',industry:'',body_or:'',season:'',tod:'',bg_blur:'',mvmt:'',aperture:'',cam_ang:'',framing:'',dof:'',col_temp:'',res:'1024x1536',ar:'2:3',fmt:'PNG',lock_eye:true,lock_bone:true,lock_lip:true,makeup_var:true,hair_var:true,rim:false,hires:false,transp:false};
const TABS=[{id:'identidad',label:'Identidad'},{id:'expresion',label:'Expresión'},{id:'estilo',label:'Estilo'},{id:'vestuario',label:'Vestuario'},{id:'pose',label:'Pose'},{id:'entorno',label:'Entorno'},{id:'camara',label:'Cámara'},{id:'generacion',label:'Generación'}];
const $=id=>document.getElementById(id);
const g=id=>{const e=$(id);return e?e.value:''};
const n=id=>{const v=parseInt(g(id));return isNaN(v)?null:v};
const setTxt=(id,v)=>{const e=$(id);if(e)e.textContent=v};
function range(id,label,min,max,val,dispId,sfx=''){return `<div class="f"><div class="fl"><label>${label}</label><span class="fv" id="${dispId}">${val}${sfx}</span></div><input type="range" id="${id}" min="${min}" max="${max}" value="${val}" oninput="update();setTxt('${dispId}',this.value+'${sfx}')"></div>`}
function txt(id,label,ph){return `<div class="f"><label>${label}</label><input type="text" id="${id}" placeholder="${ph}" oninput="update()"></div>`}
function sel(id,label,opts){const os=opts.map(o=>`<option>${o}</option>`).join('');return `<div class="f"><label>${label}</label><select id="${id}" onchange="update()"><option value="">— seleccionar —</option>${os}</select></div>`}
function tgl(key,label,opts){const bs=opts.map(([v,l])=>`<button class="to" onclick="toggleOpt('${key}','${v}',this)">${l}</button>`).join('');return `<div class="f"><label>${label}</label><div class="tg">${bs}</div></div>`}
function swRow(swId,key,lbl,initOn=false){return `<div class="sr"><span class="sl">${lbl}</span><div class="sw${initOn?' on':''}" id="${swId}" onclick="toggleSw('${swId}','${key}')"></div></div>`}
function sec(t){return `<div class="st">${t}</div>`}
function ta(id,label,ph,rows=3){return `<div class="f"><label>${label}</label><textarea id="${id}" rows="${rows}" placeholder="${ph}" oninput="update()"></textarea></div>`}
const CONTENT={
identidad:`${sec('Meta del proyecto')}${txt('p_name','Nombre del proyecto','ej. Campaign_SS25')}${txt('p_char','ID del personaje','ej. MODEL_001')}${sec('Identidad del sujeto')}${txt('p_nm','Nombre del modelo','ej. Sofia, Luca...')}${range('p_age','Edad',18,70,25,'av')}${tgl('gender','Género',[['Femenino','Femenino'],['Masculino','Masculino'],['No-binario','No-binario']])}${sel('p_arch','Arquetipo',['Editorial de lujo','Street style','Deportivo / Athleisure','Minimalista contemporáneo','Avant-garde','Casual chic','Ejecutivo profesional','Sostenible / Eco'])}${txt('p_role','Rol editorial','ej. Portada, lookbook, e-commerce')}${txt('p_brand','Alineación de marca','ej. Chanel, Nike, Zara...')}${sec('Biometría')}${tgl('body_type','Tipo de cuerpo',[['Ectomorfo','Ecto'],['Mesomorfo','Meso'],['Atlético','Atlético'],['Endomorfo','Endo'],['Curvilíneo','Curvilíneo']])}${range('p_h','Altura (cm)',155,200,175,'hv')}${sec('DNA Lock')}${swRow('sw_eye','lock_eye','Bloquear color de ojos',true)}${swRow('sw_bone','lock_bone','Bloquear estructura ósea',true)}${swRow('sw_lip','lock_lip','Bloquear forma de labios',true)}${swRow('sw_mku','makeup_var','Permitir variación de maquillaje',true)}${swRow('sw_hv','hair_var','Permitir variación de peinado',true)}${range('p_sim','Score de similitud facial',70,100,95,'sv')}`,
expresion:`${sec('Motor de expresión')}${sel('e_def','Expresión principal',['Confiada','Serena','Intensa','Alegre','Misteriosa','Soñadora','Desafiante','Neutral editorial'])}${sel('e_sec','Expresión secundaria',['Sonrisa leve','Mirada pensativa','Labios entreabiertos','Cejas arqueadas','Ojos cerrados'])}${range('e_mood','Intensidad emocional',0,10,6,'mv')}${range('e_eye','Contacto visual',0,10,7,'ev')}${tgl('smile','Tipo de sonrisa',[['Cerrada','Cerrada'],['Abierta','Abierta'],['Leve','Leve'],['Ninguna','Ninguna']])}${txt('e_emo','Emoción editorial','ej. Poder silencioso, libertad urbana...')}${sec('Proyección de marca')}${range('e_be','Energía de marca',0,10,7,'bev')}${range('e_asp','Nivel aspiracional',0,10,8,'aspv')}${range('e_rel','Relatabilidad',0,10,6,'relv')}${txt('e_voz','Voz editorial','ej. Sofisticada y accesible')}`,
estilo:`${sec('Estilo editorial')}${sel('est_cat','Categoría de estilo',['Alta moda / Couture','Ready-to-wear','Streetwear','Deportivo','Minimalista','Maximalista','Sostenible','E-commerce limpio'])}${sel('est_ton','Tono visual',['Oscuro y dramático','Luminoso y etéreo','Urbano y crudo','Cálido y dorado','Frío y clínico','Natural y orgánico','Vintage y granulado'])}${tgl('industry','Industria target',[['Moda','Moda'],['Belleza','Belleza'],['Deportes','Deportes'],['Lujo','Lujo'],['Lifestyle','Lifestyle']])}${range('est_mood','Mood de campaña',0,10,7,'cmv')}${sec('Intensidad de componentes')}${range('est_pal','Paleta de color',0,10,7,'palv')}${range('est_pe','Energía de pose',0,10,6,'pev')}${range('est_fe','Expresividad facial',0,10,7,'fev')}${range('est_ld','Drama de iluminación',0,10,8,'ldv')}${range('est_cs','Narrativa de cámara',0,10,7,'csv')}`,
vestuario:`${sec('Outfit')}${sel('v_cat','Categoría',['Vestido largo','Blazer + pantalón','Conjunto deportivo','Traje sastre','Top + falda','Overalls','Mono / Jumpsuit','Casual jeans + camiseta'])}${txt('v_ref','Referencia de estilo','ej. Parisian chic, Tokyo street...')}${tgl('season','Temporada',[['SS (Primavera-Verano)','SS'],['FW (Otoño-Invierno)','FW'],['Resort','Resort'],['Pre-Fall','Pre-Fall']])}${sec('Capas del outfit')}${txt('v_b','Capa base','ej. Camiseta blanca de algodón')}${txt('v_s','Capa secundaria','ej. Blazer oversize negro')}${txt('v_o','Capa exterior','ej. Trench coat beige')}${txt('v_acc','Accesorios','ej. Bolso mini, cinturón dorado')}${sec('Física del tejido')}${range('v_fit','Nivel de ajuste',0,10,6,'fitv')}${range('v_tr','Transparencia',0,4,1,'trv')}${tgl('mvmt','Comportamiento del tejido',[['Fluido','Fluido'],['Estructurado','Estructurado'],['Rígido','Rígido'],['Elástico','Elástico']])}`,
pose:`${sec('Configuración de pose')}${txt('po_nm','Nombre de la pose','ej. Power stance editorial')}${sel('po_sty','Estilo de pose',['Estático / Cuadro','En movimiento','Caminando','Mirando sobre el hombro','Sentado/a','Reclinado/a','De espaldas','Saltando / Dinámico'])}${tgl('body_or','Orientación del cuerpo',[['Frente a cámara','Frontal'],['3/4 izquierda','3/4 Izq'],['3/4 derecha','3/4 Der'],['Perfil','Perfil']])}${range('po_tor','Ángulo de torso (°)',-45,45,0,'torv','°')}${range('po_hip','Rotación de cadera (°)',-30,30,0,'hipv','°')}${range('po_en','Energía de pose',0,10,6,'env')}${txt('po_arm','Posición de brazos','ej. Un brazo doblado, otro extendido')}${txt('po_act','Acción editorial','ej. Sostiene sombrero, ajusta solapa...')}`,
entorno:`${sec('Localización')}${sel('en_loc','Tipo de locación',['Estudio blanco (high key)','Estudio negro (low key)','Interior loft industrial','Interior de lujo / mansión','Exterior urbano','Exterior natural / campo','Rooftop','Pasarela'])}${txt('en_sty','Estilo de escena','ej. Nueva York industrial, Toscana cálida...')}${tgl('tod','Momento del día',[['Amanecer','Amanecer'],['Mediodía','Mediodía'],['Golden hour','Golden hour'],['Atardecer','Atardecer'],['Noche','Noche']])}${sel('en_amb','Energía ambiente',['Silencioso y contemplativo','Dinámico y urbano','Cálido y acogedor','Frío y minimalista','Natural y orgánico','Lujoso y opulento'])}${tgl('bg_blur','Desenfoque de fondo',[['Ninguno','Ninguno'],['Leve','Leve'],['Moderado','Moderado'],['Fuerte (bokeh)','Bokeh']])}${txt('en_prop','Props en escena','ej. Sostiene taza, silla Eames...')}${txt('en_cg','Color grading','ej. Teal y orange, moody desaturado...')}${sec('Iluminación')}${sel('lt_sty','Estilo de iluminación',['Rembrandt','Butterfly / Paramount','Loop','Split','Flat / Beauty','Dramático lateral','Natural difuso','Contraluz / Backlit'])}${tgl('col_temp','Temperatura de color',[['Fría (5500K)','Fría'],['Natural (4200K)','Natural'],['Cálida (3200K)','Cálida'],['Golden (2800K)','Golden']])}${range('lt_sk','Especular de piel',0,10,5,'skv')}${swRow('sw_rim','rim','Activar rim light',false)}`,
camara:`${sec('Configuración de cámara')}${sel('cm_type','Tipo de cámara',['DSLR full frame','Medium format (Hasselblad)','Mirrorless','Film analógico 35mm','Film analógico medio formato','Polaroid / Instantánea'])}${range('cm_lens','Focal length (mm)',24,200,85,'lensv','mm')}${tgl('aperture','Apertura',[['f/1.4','f/1.4'],['f/1.8','f/1.8'],['f/2.8','f/2.8'],['f/4','f/4'],['f/8','f/8']])}${tgl('cam_ang','Ángulo de cámara',[['Eye level','Eye level'],['Ligeramente bajo','Bajo'],['Ligeramente alto','Alto'],['Picado','Picado']])}${tgl('framing','Encuadre',[['Full body','Full body'],['3/4 body','3/4'],['Half body','Half'],['Retrato','Retrato'],['Close-up facial','Close-up']])}${tgl('dof','Profundidad de campo',[['Muy estrecha','Muy estrecha'],['Estrecha','Estrecha'],['Media','Media'],['Profunda','Profunda']])}${range('cm_st','Storytelling visual',0,10,7,'stv')}`,
generacion:`${sec('Prompts')}${ta('gn_main','Prompt principal','ej. Editorial fashion photography, high-end luxury brand campaign...',4)}${txt('gn_va','Variación A','Variación A...')}${txt('gn_vb','Variación B','Variación B...')}${sec('Parámetros técnicos')}${sel('gn_samp','Método de sampling',['DPM++ 2M Karras','DPM++ SDE Karras','Euler a','DDIM','PLMS'])}${range('gn_st','Steps',10,150,30,'stpv')}${range('gn_cfg','CFG Scale',1,20,7,'cfgv')}${swRow('sw_hires','hires','Hires Fix',false)}${range('gn_up','Factor de upscale',1,4,2,'upv','x')}${sec('Exportación')}${tgl('res','Resolución',[['512x512','512²'],['768x1024','768×1024'],['1024x1024','1024²'],['1024x1536','1024×1536']])}${tgl('ar','Aspect ratio',[['1:1','1:1'],['4:5','4:5'],['2:3','2:3'],['9:16','9:16']])}${tgl('fmt','Formato de archivo',[['PNG','PNG'],['JPEG','JPEG'],['WEBP','WEBP']])}${swRow('sw_tr','transp','Fondo transparente',false)}${sec('Negative prompt')}${ta('gn_neg','Negative prompt','ej. blurry, ugly, deformed, watermark, text...',3)}`
};
function buildUI(){
  const tabsEl=$('tabs'),formsEl=$('forms');
  TABS.forEach((t,i)=>{
    const btn=document.createElement('button');
    btn.className='tb'+(i===0?' on':'');
    btn.textContent=t.label;
    btn.onclick=()=>switchTab(t.id,btn);
    tabsEl.appendChild(btn);
    const div=document.createElement('div');
    div.className='tc'+(i===0?' on':'');
    div.id='tc-'+t.id;
    div.innerHTML=CONTENT[t.id];
    formsEl.appendChild(div);
  });
  setTimeout(()=>{markDefault('res','1024x1536');markDefault('ar','2:3');markDefault('fmt','PNG');update();},50);
}
function markDefault(key,val){
  document.querySelectorAll('.to').forEach(b=>{
    if(b.getAttribute('onclick')&&b.getAttribute('onclick').includes(`'${key}'`)&&b.getAttribute('onclick').includes(`'${val}'`)){b.classList.add('s');}
  });
  S[key]=val;
}
function switchTab(id,btn){
  document.querySelectorAll('.tc').forEach(t=>t.classList.remove('on'));
  document.querySelectorAll('.tb').forEach(b=>b.classList.remove('on'));
  $('tc-'+id).classList.add('on');btn.classList.add('on');
}
function toggleOpt(key,val,el){
  const grp=el.closest('.tg');
  if(grp)grp.querySelectorAll('.to').forEach(b=>b.classList.remove('s'));
  el.classList.add('s');S[key]=val;update();
}
function toggleSw(swId,key){
  const sw=$(swId);sw.classList.toggle('on');S[key]=sw.classList.contains('on');update();
}
function buildJSON(){
  return {
    meta_system:{project_name:g('p_name')||null,character_id:g('p_char')||null,version:"EDITORIAL_MODEL_V1",consistency_lock:true,generation_count:0},
    dna_hash_system:{enabled:true,consistency_rules:{lock_eye_color:S.lock_eye,lock_bone_structure:S.lock_bone,lock_lip_shape:S.lock_lip,allow_makeup_variation:S.makeup_var,allow_hairstyle_variation:S.hair_var},mutation_control:{max_allowed_variation_percent:2,face_similarity_score_target_0_100:n('p_sim')??95}},
    subject_system:{identity:{name:g('p_nm')||null,age:n('p_age'),gender:S.gender||null,archetype:g('p_arch')||null,editorial_role:g('p_role')||null,brand_alignment:g('p_brand')||null},biometrics:{height_cm:n('p_h'),body_type:S.body_type||null},expression_engine:{default_expression:g('e_def')||null,secondary_expression:g('e_sec')||null,mood_intensity_0_10:n('e_mood'),eye_contact_strength_0_10:n('e_eye'),smile_type:S.smile||null,editorial_emotion:g('e_emo')||null}},
    editorial_style_system:{style_category:g('est_cat')||null,visual_tone:g('est_ton')||null,target_industry:S.industry||null,campaign_mood_0_10:n('est_mood'),components:{color_palette_strength_0_10:n('est_pal'),pose_energy_0_10:n('est_pe'),facial_expressiveness_0_10:n('est_fe'),lighting_drama_0_10:n('est_ld'),camera_storytelling_0_10:n('est_cs')}},
    brand_projection:{brand_energy_level_0_10:n('e_be'),aspirational_level_0_10:n('e_asp'),relatability_level_0_10:n('e_rel'),editorial_voice:g('e_voz')||null},
    wardrobe_engine:{outfit_category:g('v_cat')||null,style_reference:g('v_ref')||null,season:S.season||null,layering_system:{base_layer:g('v_b')||null,secondary_layer:g('v_s')||null,outer_layer:g('v_o')||null,accessories:g('v_acc')||null},fabric_physics:{fit_level_0_10:n('v_fit'),transparency_level_0_10:n('v_tr'),movement_behavior:S.mvmt||null},coverage_protocol:{explicit_nudity_allowed:false,minimum_coverage_enforced:true,age_appropriate_enforced:true}},
    pose_engine:{pose_name:g('po_nm')||null,pose_style:g('po_sty')||null,body_orientation:S.body_or||null,torso_angle_degree:n('po_tor'),hip_rotation_degree:n('po_hip'),energy_level_0_10:n('po_en'),arm_positioning:g('po_arm')||null,editorial_action:g('po_act')||null,forbidden_pose_conditions:["explicit_spread","genital_exposure","sexual_simulation","suggestive_touching"]},
    environment_system:{location_type:g('en_loc')||null,setting_style:g('en_sty')||null,background_blur_level:S.bg_blur||null,prop_interaction:g('en_prop')||null,time_of_day:S.tod||null,ambient_energy:g('en_amb')||null,color_grading_reference:g('en_cg')||null},
    lighting_engine:{lighting_style:g('lt_sty')||null,key_light:{color_temperature:S.col_temp||null},rim_light:{enabled:S.rim},skin_specular_intensity_0_10:n('lt_sk')},
    camera_engine:{camera_type:g('cm_type')||null,lens_mm:n('cm_lens'),aperture:S.aperture||null,camera_angle:S.cam_ang||null,framing_type:S.framing||null,focus_target:"eyes",depth_of_field_strength:S.dof||null,storytelling_level_0_10:n('cm_st')},
    safety_compliance_layer:{explicit_content_block:true,sexual_act_block:true,minor_protection_enforced:true,no_genital_focus:true,no_intimate_area_exposure:true,age_appropriate_content_only:true},
    negative_prompt:g('gn_neg').split(',').map(s=>s.trim()).filter(Boolean),
    generation_engine:{primary_prompt:g('gn_main')||null,variation_prompts:[g('gn_va'),g('gn_vb')].filter(Boolean),sampling_method:g('gn_samp')||null,steps:n('gn_st'),guidance_scale:n('gn_cfg'),hires_fix:S.hires,upscale_factor:n('gn_up')},
    export_settings:{resolution:S.res||null,aspect_ratio:S.ar||null,file_format:S.fmt||null,transparent_background:S.transp}
  };
}
function hl(obj){
  return JSON.stringify(obj,null,2)
    .replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;')
    .replace(/"([^"]+)":/g,(_,k)=>`<span class="jk">"${k}"</span>:`)
    .replace(/: "([^"]*)"/g,(_,v)=>v?`: <span class="js">"${v}"</span>`:`: <span class="jnu">null</span>`)
    .replace(/: (true)/g,': <span class="jt">true</span>')
    .replace(/: (false)/g,': <span class="jf">false</span>')
    .replace(/: (null)/g,': <span class="jnu">null</span>')
    .replace(/: (-?\\d+)/g,': <span class="jn">$1</span>');
}
function update(){$('out').innerHTML=hl(buildJSON());}
function sendToNative(){
  const json=JSON.stringify(buildJSON(),null,2);
  if(window.webkit?.messageHandlers?.jsonReady){
    window.webkit.messageHandlers.jsonReady.postMessage(json);
  }
}
buildUI();
</script>
</body>
</html>
"""
}
