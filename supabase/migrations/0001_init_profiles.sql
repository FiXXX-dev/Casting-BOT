-- =====================================================================
-- Casting-BOT · Supabase schema (profiles)
-- Покрывает оба раздела мини-аппа: «Что ищу» и «Моя анкета».
-- Эталон полей: index.html
-- =====================================================================

-- gen_random_uuid() доступна в Supabase (расширение pgcrypto уже включено),
-- но включим явно на случай чистой базы.
create extension if not exists pgcrypto;

-- ---------------------------------------------------------------------
-- updated_at: общий триггер, чтобы не дублировать логику в каждой таблице
-- ---------------------------------------------------------------------
create or replace function set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

-- =====================================================================
-- 1. actors — якорь профиля (одна запись на пользователя Telegram)
--    Связь telegram_user_id <-> профиль живёт здесь.
-- =====================================================================
create table actors (
  id                 uuid        primary key default gen_random_uuid(),
  telegram_user_id   bigint      not null unique,   -- id из Telegram (ключ для бота)
  telegram_username  text,                          -- @username аккаунта (может меняться, не для связи)
  is_active          boolean     not null default true,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now()
);

comment on table  actors is 'Аккаунт актёра. Один к одному с пользователем Telegram.';
comment on column actors.telegram_user_id is 'Telegram user id. Натуральный ключ, по нему бот находит профиль. BIGINT — id выходят за пределы int4.';

create trigger trg_actors_updated_at
  before update on actors
  for each row execute function set_updated_at();

-- =====================================================================
-- 2. search_filters — раздел «Что ищу» (1:1 с actor)
--    Это читает движок мэтчинга, поэтому фильтруемые поля — колонками.
-- =====================================================================
create table search_filters (
  actor_id        uuid        primary key references actors(id) on delete cascade,

  -- блок «Кто ты в кадре»
  gender          text        check (gender in ('male', 'female')),   -- Пол (single)
  play_age_min    smallint    check (play_age_min between 1 and 99),   -- игровой возраст «от»
  play_age_max    smallint    check (play_age_max between 1 and 99),   -- игровой возраст «до»
  search_city     text,                                               -- «Где ищем»: tashkent / moscow / any

  -- блок «Типы проектов»
  project_types   text[]      not null default '{}',                  -- мультиселект: film/ad/model/voiceover
  min_rate        integer     check (min_rate >= 0),                  -- мин. ставка в сумах, NULL = показывать всё

  -- блок «Что не присылать» — две именованные группы стоп-слов
  exclusions      jsonb       not null default '{}'::jsonb,           -- {"specifics": [...], "typecasts": [...]}

  -- охват (верхний переключатель в фильтрах)
  reach           text        not null default 'broad'
                              check (reach in ('broad', 'exact')),

  updated_at      timestamptz not null default now(),

  constraint play_age_order check (
    play_age_min is null or play_age_max is null or play_age_min <= play_age_max
  )
);

comment on table  search_filters is 'Раздел «Что ищу». Критерии подбора кастингов.';
comment on column search_filters.project_types is 'Мультиселект типов проектов. text[] ради быстрых overlap-операторов (&&) в мэтчинге.';
comment on column search_filters.exclusions   is 'Стоп-слова по группам: {"specifics":[...],"typecasts":[...]}. JSONB — структура может расти.';
comment on column search_filters.reach        is 'broad = шире охват, exact = точное совпадение.';

create trigger trg_search_filters_updated_at
  before update on search_filters
  for each row execute function set_updated_at();

-- GIN-индекс под основной запрос мэтчинга: «у кого в фильтрах есть тип X»
create index idx_search_filters_project_types on search_filters using gin (project_types);
create index idx_search_filters_exclusions    on search_filters using gin (exclusions);

-- =====================================================================
-- 3. portfolios — раздел «Моя анкета» (1:1 с actor)
--    В основном статичные данные для автозаполнения откликов.
-- =====================================================================
create table portfolios (
  actor_id                uuid        primary key references actors(id) on delete cascade,

  -- блок «О себе»
  full_name               text,
  age                     smallint    check (age between 1 and 120),   -- реальный возраст
  city                    text,                                        -- город проживания (select)
  travel_ready            boolean     not null default false,          -- готов к командировкам (switch)
  employment              text        check (employment in ('self_employed', 'ip', 'individual')), -- как оформлен
  eye_color               text,                                        -- цвет глаз (select)
  distinguishing_features text[]      not null default '{}',           -- особые приметы (мультичипы)

  -- блок «Опыт и обучение»
  has_experience          boolean,                                     -- снимался раньше (Да / Пока нет)
  education               text        check (education in
                            ('university', 'courses', 'university_and_courses', 'none')),

  -- блок «Что умею» — навыки по группам
  skills                  jsonb       not null default '{}'::jsonb,    -- {"sport":[],"dance":[],"vocal":[],"instruments":[],"languages":[]}

  -- блок «Связь и материалы»
  portfolio_url           text,
  showreel_url            text,
  phone                   text,
  contact_telegram        text,                                        -- @username, который актёр указал для связи
  email                   text,

  updated_at              timestamptz not null default now()
);

comment on table  portfolios is 'Раздел «Моя анкета». Портфолио для автозаполнения откликов.';
comment on column portfolios.skills is 'Навыки по группам: {"sport":[],"dance":[],"vocal":[],"instruments":[],"languages":[]}. JSONB — вложенная структура, читается LLM как есть.';
comment on column portfolios.distinguishing_features is 'Плоский мультиселект примет. text[] достаточно, группировки нет.';

create trigger trg_portfolios_updated_at
  before update on portfolios
  for each row execute function set_updated_at();

-- опционально: искать актёров по навыкам/языкам
create index idx_portfolios_skills on portfolios using gin (skills);

-- =====================================================================
-- 4. RLS — включаем на всех таблицах.
--    Писатель — бот/бэкенд через service_role key (обходит RLS).
--    Политики ниже нужны ТОЛЬКО если мини-апп ходит в Supabase напрямую
--    с JWT, где telegram_user_id лежит в claim (например, выданный
--    edge-функцией после проверки Telegram initData).
-- =====================================================================
alter table actors          enable row level security;
alter table search_filters  enable row level security;
alter table portfolios      enable row level security;

-- Пример политики (раскомментировать после выбора схемы аутентификации).
-- Предполагается JWT с claim "telegram_user_id".
--
-- create policy "actor reads own row" on actors
--   for select using (telegram_user_id = (auth.jwt() ->> 'telegram_user_id')::bigint);
--
-- create policy "actor edits own filters" on search_filters
--   for all using (
--     actor_id in (
--       select id from actors
--       where telegram_user_id = (auth.jwt() ->> 'telegram_user_id')::bigint
--     )
--   );
