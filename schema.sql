-- Manutec · esquema para Supabase/PostgreSQL (espelha exatamente as tabelas que o app já gera em toDB()).
-- Rode no SQL Editor do Supabase.
create extension if not exists pgcrypto;

create table usuarios (
  id uuid primary key default gen_random_uuid(),
  auth_user_id uuid unique references auth.users(id) on delete set null, -- vínculo com o login (Supabase Auth)
  nome text not null, email text not null unique,
  perfil text not null check (perfil in ('Administrador','Comercial','Operacional','Financeiro','Motorista')),
  created_at timestamptz default now()
);
create table clientes (
  id uuid primary key default gen_random_uuid(),
  nome text not null, doc text not null unique, ie text, contato text, tel text, email text, endereco text not null,
  created_at timestamptz default now()
);
create table ativos (
  id uuid primary key default gen_random_uuid(),
  tag text not null unique, tipo text not null check (tipo in ('Empilhadeira','Munck','Plataforma Elevatória')),
  descricao text not null, modalidade text not null check (modalidade in ('Diária','KM','Horas (Horímetro)','Mensal')),
  status text not null default 'Disponível' check (status in ('Disponível','Em Locação','Indisponível')),
  created_at timestamptz default now()
);
create table locacoes (
  id uuid primary key default gen_random_uuid(),
  numero text not null unique,
  cliente_id uuid not null references clientes(id) on delete restrict,
  ativo_id uuid not null references ativos(id) on delete restrict,
  endereco_entrega text not null,
  data_entrega date not null, hora_entrega time not null,
  data_retirada date not null, hora_retirada time not null,
  pagamento text,
  valor_diaria numeric(12,2), qtd_diarias numeric(8,1) check (qtd_diarias is null or (qtd_diarias >= 0 and qtd_diarias*2 = round(qtd_diarias*2))), -- múltiplos de 0,5
  valor_km numeric(12,2), km_rodados numeric(10,1), -- só Munck
  valor numeric(12,2) not null check (valor > 0),
  status text not null default 'Pendente' check (status in ('Pendente','Entregue')),
  conferido boolean not null default false,
  canhoto_url text, -- arquivo no Storage (bucket "canhotos"), enviado pelo app do motorista
  fatura_status text not null default 'Pendente de Emissão' check (fatura_status in ('Pendente de Emissão','Gerada','Paga')),
  created_at timestamptz default now(),
  check (data_retirada >= data_entrega)
);
create table cotacoes (
  id uuid primary key default gen_random_uuid(),
  numero text not null unique,
  cliente_id uuid not null references clientes(id) on delete restrict,
  ativo_id uuid not null references ativos(id) on delete restrict,
  valor_diaria numeric(12,2), qtd_diarias numeric(8,1), valor_km numeric(12,2), km_rodados numeric(10,1),
  valor numeric(12,2) not null, inicio date not null, fim date not null, validade date not null,
  status text not null default 'Pendente' check (status in ('Pendente','Aprovado','Não Aprovado')),
  locacao_id uuid references locacoes(id) on delete set null, -- preenchido ao converter em locação
  created_at timestamptz default now()
);
create table contratos (
  id uuid primary key default gen_random_uuid(),
  numero text not null unique,
  cliente_id uuid not null references clientes(id) on delete restrict,
  ativo_id uuid not null references ativos(id) on delete restrict,
  valor_mensal numeric(12,2) not null, inicio date not null, meses int not null check (meses >= 1),
  dia_vencimento int not null check (dia_vencimento between 1 and 31),
  ultima_fatura text, -- 'AAAA-MM'
  created_at timestamptz default now()
);
create table ordens_servico (
  id uuid primary key default gen_random_uuid(),
  numero text not null unique,
  tipo text not null check (tipo in ('Entrega','Retirada','Serviço')),
  locacao_id uuid references locacoes(id) on delete restrict,
  cliente_id uuid not null references clientes(id) on delete restrict,
  ativo_id uuid not null references ativos(id) on delete restrict,
  motorista_id uuid references usuarios(id) on delete set null,
  endereco text not null, data date not null, hora time not null,
  status text not null default 'Aberta' check (status in ('Aberta','Em rota','Concluída','Cancelada')),
  execucao text not null default 'Não realizada' check (execucao in ('Não realizada','Realizada')),
  executada_em timestamptz,  -- o app do motorista grava ao confirmar
  canhoto_url text,          -- assinatura do cliente (app do motorista)
  recebedor_nome text, recebedor_doc text, recebedor_doc_tipo text, recebedor_tel text, -- dados do recebedor (app do motorista)
  condicao text, ocorrencias text,                                                      -- condição do equipamento na entrega/retirada
  ass_motorista text, ass_cliente text,                                                 -- assinaturas (PNG base64); o ideal é migrar p/ Supabase Storage
  observacoes text, created_at timestamptz default now()
);
create index on locacoes (cliente_id); create index on locacoes (ativo_id); create index on locacoes (data_entrega);
create index on ordens_servico (motorista_id, data); create index on ordens_servico (locacao_id);

-- Segurança (RLS). Ajuste as regras por perfil conforme a necessidade.
do $$ declare t text; begin
  foreach t in array array['usuarios','clientes','ativos','locacoes','cotacoes','contratos','ordens_servico'] loop
    execute format('alter table %I enable row level security', t);
    execute format('create policy "autenticados" on %I for all to authenticated using (true) with check (true)', t);
  end loop; end $$;
-- Motorista: só deveria ver/atualizar as próprias OS (substitua a política acima de ordens_servico):
--   using (motorista_id = (select id from usuarios where auth_user_id = auth.uid()) or
--          exists (select 1 from usuarios where auth_user_id = auth.uid() and perfil <> 'Motorista'))

-- Regra de negócio: toda locação nasce com uma OS de entrega (o app já cria as duas juntas).
-- No banco, o ideal é inserir locação + OS na mesma transação (função RPC), pois são tabelas separadas.

-- ===== COMO LIGAR OS APPS =====
-- 1) Rode este arquivo inteiro no SQL Editor do Supabase.
-- 2) Authentication > Users > "Add user": crie 1 usuário (ex.: sistema@suaempresa.com + senha). Pode usar o mesmo login nos dois apps.
--    (Authentication > Providers > Email: desligue "Confirm email" para entrar sem confirmar.)
-- 3) Em Project Settings > API copie: Project URL e a chave "anon/public". NUNCA use a service_role nos apps.
-- 4) No sistema e no app do motorista clique em "Offline — conectar ao banco", cole URL + chave pública + e-mail/senha.
--    Na 1ª conexão do sistema com o banco vazio, os dados do navegador (usuários, etc.) sobem automaticamente.
