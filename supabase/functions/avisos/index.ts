// Ponto AVP — avisos no celular dos fiscais
// acao "verificar": chamada a cada 5 minutos pelo agendador; avisa quem passou do horário sem bater a entrada
// acao "teste": manda um aviso de teste para os celulares de quem chamou
// acao "criar_fiscal" / "remover_fiscal": só administrador
import webpush from "npm:web-push@3.6.7";
import { createClient } from "npm:@supabase/supabase-js@2.45.4";

const SB_URL = Deno.env.get("SUPABASE_URL")!;
const SRK = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const sb = createClient(SB_URL, SRK, { auth: { persistSession: false } });
const PAINEL = "https://andersonveloso0503-cmyk.github.io/ponto-avp/admin.html";
const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const resp = (obj: unknown, status = 200) =>
  new Response(JSON.stringify(obj), { status, headers: { ...CORS, "Content-Type": "application/json" } });

let vapidPronto = false;
async function prepararVapid() {
  if (vapidPronto) return;
  const { data, error } = await sb.rpc("vapid_chaves");
  if (error || !data?.publica || !data?.privada) throw new Error("Chaves de aviso não configuradas.");
  webpush.setVapidDetails("https://andersonveloso0503-cmyk.github.io/ponto-avp/", data.publica, data.privada);
  vapidPronto = true;
}

type Insc = { id: number; endpoint: string; p256dh: string; auth: string };
async function enviar(inscs: Insc[], aviso: Record<string, unknown>) {
  await prepararVapid();
  let ok = 0;
  for (const i of inscs) {
    try {
      await webpush.sendNotification({ endpoint: i.endpoint, keys: { p256dh: i.p256dh, auth: i.auth } },
        JSON.stringify(aviso), { TTL: 3600, urgency: "high" });
      ok++;
    } catch (e) {
      const cod = (e as { statusCode?: number }).statusCode;
      if (cod === 404 || cod === 410) await sb.from("push_inscricoes").delete().eq("id", i.id); // celular desativou
      else console.error("falha ao enviar", cod, String(e));
    }
  }
  return ok;
}

async function usuarioDaChamada(req: Request) {
  const token = (req.headers.get("Authorization") || "").replace(/^Bearer\s+/i, "");
  if (!token) return null;
  const { data } = await sb.auth.getUser(token);
  if (!data?.user) return null;
  const { data: g } = await sb.from("admins").select("papel").eq("user_id", data.user.id).maybeSingle();
  return g ? { id: data.user.id, papel: g.papel as string } : null;
}

const hora = (d: string) => new Date(d).toLocaleTimeString("pt-BR", { timeZone: "America/Sao_Paulo", hour: "2-digit", minute: "2-digit" });

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  let corpo: Record<string, string> = {};
  try { corpo = await req.json(); } catch { /* sem corpo */ }
  const acao = corpo.acao || "verificar";

  try {
    if (acao === "verificar") {
      const { data: atrasos, error } = await sb.rpc("pegar_atrasos");
      if (error) throw error;
      if (!atrasos?.length) return resp({ ok: true, avisos: 0 });
      const { data: gest } = await sb.from("admins").select("user_id");
      const ids = (gest || []).map((g) => g.user_id);
      const { data: inscs } = await sb.from("push_inscricoes").select("id,endpoint,p256dh,auth").in("user_id", ids);
      if (!inscs?.length) return resp({ ok: true, avisos: atrasos.length, enviados: 0 });
      let enviados = 0;
      if (atrasos.length <= 3) {
        for (const a of atrasos) {
          enviados += await enviar(inscs, {
            titulo: `Sem entrada: ${a.nome}`,
            corpo: `${a.posto} · horário ${hora(a.previsto)}. Ainda não bateu o ponto.`,
            url: PAINEL, tag: `atraso-${a.colaborador_id}`,
          });
        }
      } else {
        const nomes = atrasos.slice(0, 6).map((a: { nome: string; posto: string }) => `${a.nome.split(" ")[0]} (${a.posto})`).join(", ");
        enviados += await enviar(inscs, {
          titulo: `${atrasos.length} funcionários sem entrada`,
          corpo: nomes + (atrasos.length > 6 ? ` e mais ${atrasos.length - 6}` : ""),
          url: PAINEL, tag: "atrasos",
        });
      }
      return resp({ ok: true, avisos: atrasos.length, enviados });
    }

    const u = await usuarioDaChamada(req);
    if (!u) return resp({ ok: false, motivo: "Sem permissão." }, 401);

    if (acao === "teste") {
      const { data: inscs } = await sb.from("push_inscricoes").select("id,endpoint,p256dh,auth").eq("user_id", u.id);
      if (!inscs?.length) return resp({ ok: false, motivo: "Este usuário ainda não ativou os avisos em nenhum celular." });
      const n = await enviar(inscs, { titulo: "Ponto AVP · aviso de teste", corpo: "Os avisos estão funcionando neste celular.", url: PAINEL, tag: "teste" });
      return resp({ ok: n > 0, enviados: n, motivo: n ? undefined : "O aviso não foi entregue. Desative e ative os avisos de novo." });
    }

    if (u.papel !== "admin") return resp({ ok: false, motivo: "Só o administrador pode fazer isso." }, 403);

    if (acao === "criar_fiscal") {
      const email = String(corpo.email || "").trim().toLowerCase(), senha = String(corpo.senha || ""), nome = String(corpo.nome || "").trim();
      if (!nome || !/^\S+@\S+\.\S+$/.test(email)) return resp({ ok: false, motivo: "Informe nome e e-mail válidos." });
      if (senha.length < 6) return resp({ ok: false, motivo: "A senha precisa ter pelo menos 6 caracteres." });
      const { data: criado, error } = await sb.auth.admin.createUser({ email, password: senha, email_confirm: true, user_metadata: { nome } });
      if (error) return resp({ ok: false, motivo: /registered|exists/i.test(error.message) ? "Já existe um acesso com esse e-mail." : error.message });
      const { error: e2 } = await sb.from("admins").insert({ user_id: criado.user.id, nome, email, papel: "fiscal" });
      if (e2) { await sb.auth.admin.deleteUser(criado.user.id); return resp({ ok: false, motivo: e2.message }); }
      return resp({ ok: true });
    }

    if (acao === "remover_fiscal") {
      const alvo = String(corpo.user_id || "");
      const { data: f } = await sb.from("admins").select("papel").eq("user_id", alvo).maybeSingle();
      if (!f || f.papel !== "fiscal") return resp({ ok: false, motivo: "Fiscal não encontrado." });
      await sb.from("admins").delete().eq("user_id", alvo);
      await sb.auth.admin.deleteUser(alvo);
      return resp({ ok: true });
    }

    return resp({ ok: false, motivo: "Ação desconhecida." }, 400);
  } catch (e) {
    console.error(e);
    return resp({ ok: false, motivo: String((e as Error).message || e) }, 500);
  }
});
