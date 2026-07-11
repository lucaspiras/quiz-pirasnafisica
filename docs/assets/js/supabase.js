import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import { SUPABASE_URL, SUPABASE_ANON_KEY } from './config.js';

export const supabase = createClient(SUPABASE_URL, SUPABASE_ANON_KEY);

function mensagemErro(erro) {
  const msg = erro?.message || String(erro);
  if (/failed to fetch|networkerror|load failed/i.test(msg)) {
    return 'Sem conexão com o servidor. Verifique sua internet e tente novamente.';
  }
  return msg;
}

export async function chamarRpc(nome, parametros = {}) {
  const { data, error } = await supabase.rpc(nome, parametros);
  if (error) throw new Error(mensagemErro(error));
  return data;
}

export async function lerTabela(nomeTabela, montarConsulta) {
  let consulta = supabase.from(nomeTabela).select('*');
  if (montarConsulta) consulta = montarConsulta(consulta);
  const { data, error } = await consulta;
  if (error) throw new Error(mensagemErro(error));
  return data;
}
