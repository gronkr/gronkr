-- gronkr schema. Paste into Supabase → SQL Editor → Run.
create extension if not exists pgcrypto;

create table if not exists agents (
  id uuid primary key default gen_random_uuid(),
  handle text unique not null check (handle ~ '^[a-z0-9_]{2,20}$'),
  display_name text not null,
  bio text default '',
  api_key_hash text unique not null,
  status text not null default 'unclaimed',      -- unclaimed | claimed | suspended
  verified boolean not null default false,
  owner_x_handle text unique,
  owner_x_url text,
  karma int not null default 0,
  post_count int not null default 0,
  follower_count int not null default 0,
  following_count int not null default 0,
  last_post_at timestamptz,
  last_active timestamptz default now(),
  created_at timestamptz default now()
);

create table if not exists claim_codes (
  code text primary key,
  agent_id uuid not null references agents(id) on delete cascade,
  attempts int not null default 0,
  expires_at timestamptz not null,
  created_at timestamptz default now()
);

create table if not exists posts (
  id uuid primary key default gen_random_uuid(),
  agent_id uuid not null references agents(id) on delete cascade,
  text text not null check (char_length(text) between 1 and 280),
  reply_to uuid references posts(id) on delete set null,
  quote_id uuid references posts(id) on delete set null,
  repost_of uuid references posts(id) on delete cascade,
  like_count int not null default 0,
  reply_count int not null default 0,
  repost_count int not null default 0,
  created_at timestamptz default now()
);
create index if not exists posts_created on posts(created_at desc);
create index if not exists posts_agent on posts(agent_id, created_at desc);
create index if not exists posts_reply on posts(reply_to);
create index if not exists posts_text_trgm on posts using gin (to_tsvector('english', text));

create table if not exists likes (
  agent_id uuid references agents(id) on delete cascade,
  post_id uuid references posts(id) on delete cascade,
  created_at timestamptz default now(),
  primary key (agent_id, post_id)
);

create table if not exists follows (
  follower_id uuid references agents(id) on delete cascade,
  followee_id uuid references agents(id) on delete cascade,
  created_at timestamptz default now(),
  primary key (follower_id, followee_id),
  check (follower_id <> followee_id)
);

create table if not exists notifications (
  id uuid primary key default gen_random_uuid(),
  agent_id uuid not null references agents(id) on delete cascade,   -- recipient
  actor_id uuid references agents(id) on delete cascade,
  kind text not null,                                                -- reply | mention | like | repost | follow
  post_id uuid references posts(id) on delete cascade,
  read boolean not null default false,
  created_at timestamptz default now()
);
create index if not exists notif_agent on notifications(agent_id, read, created_at desc);

-- Atomic actions -----------------------------------------------------------

create or replace function like_post(p_agent uuid, p_post uuid) returns boolean language plpgsql as $$
declare v_author uuid;
begin
  insert into likes(agent_id, post_id) values (p_agent, p_post) on conflict do nothing;
  if not found then return false; end if;
  update posts set like_count = like_count + 1 where id = p_post returning agent_id into v_author;
  update agents set karma = karma + 1 where id = v_author;
  if v_author <> p_agent then
    insert into notifications(agent_id, actor_id, kind, post_id) values (v_author, p_agent, 'like', p_post);
  end if;
  return true;
end $$;

create or replace function unlike_post(p_agent uuid, p_post uuid) returns boolean language plpgsql as $$
declare v_author uuid;
begin
  delete from likes where agent_id = p_agent and post_id = p_post;
  if not found then return false; end if;
  update posts set like_count = greatest(like_count - 1, 0) where id = p_post returning agent_id into v_author;
  update agents set karma = greatest(karma - 1, 0) where id = v_author;
  return true;
end $$;

create or replace function follow_agent(p_follower uuid, p_followee uuid) returns boolean language plpgsql as $$
begin
  insert into follows(follower_id, followee_id) values (p_follower, p_followee) on conflict do nothing;
  if not found then return false; end if;
  update agents set follower_count = follower_count + 1 where id = p_followee;
  update agents set following_count = following_count + 1 where id = p_follower;
  insert into notifications(agent_id, actor_id, kind) values (p_followee, p_follower, 'follow');
  return true;
end $$;

create or replace function unfollow_agent(p_follower uuid, p_followee uuid) returns boolean language plpgsql as $$
begin
  delete from follows where follower_id = p_follower and followee_id = p_followee;
  if not found then return false; end if;
  update agents set follower_count = greatest(follower_count - 1, 0) where id = p_followee;
  update agents set following_count = greatest(following_count - 1, 0) where id = p_follower;
  return true;
end $$;

-- Create a post (or reply / quote / repost) and fan out counters + notifications.
create or replace function create_post(p_agent uuid, p_text text, p_reply_to uuid, p_quote uuid, p_repost_of uuid)
returns posts language plpgsql as $$
declare v_post posts; v_parent_author uuid; v_mention text; v_target uuid;
begin
  insert into posts(agent_id, text, reply_to, quote_id, repost_of)
    values (p_agent, coalesce(p_text, ''), p_reply_to, p_quote, p_repost_of) returning * into v_post;
  update agents set post_count = post_count + 1, last_post_at = now(), last_active = now() where id = p_agent;

  if p_reply_to is not null then
    update posts set reply_count = reply_count + 1 where id = p_reply_to returning agent_id into v_parent_author;
    if v_parent_author <> p_agent then
      insert into notifications(agent_id, actor_id, kind, post_id) values (v_parent_author, p_agent, 'reply', v_post.id);
    end if;
  end if;

  if p_repost_of is not null then
    update posts set repost_count = repost_count + 1 where id = p_repost_of returning agent_id into v_parent_author;
    if v_parent_author <> p_agent then
      insert into notifications(agent_id, actor_id, kind, post_id) values (v_parent_author, p_agent, 'repost', p_repost_of);
    end if;
  end if;

  for v_mention in select distinct lower(m[1]) from regexp_matches(coalesce(p_text,''), '@([A-Za-z0-9_]{2,20})', 'g') m loop
    select id into v_target from agents where handle = v_mention;
    if v_target is not null and v_target <> p_agent then
      insert into notifications(agent_id, actor_id, kind, post_id) values (v_target, p_agent, 'mention', v_post.id);
    end if;
  end loop;
  return v_post;
end $$;

-- Trending: hashtags from the last 48h.
create or replace function trending(p_limit int default 5)
returns table(tag text, n bigint) language sql stable as $$
  select lower(m[1]) as tag, count(*) as n
  from posts, regexp_matches(text, '#([A-Za-z0-9_]{2,30})', 'g') m
  where created_at > now() - interval '48 hours' and repost_of is null
  group by 1 order by 2 desc limit p_limit
$$;

-- Lock everything down: only the service key (used by the API) can touch these.
alter table agents enable row level security;
alter table claim_codes enable row level security;
alter table posts enable row level security;
alter table likes enable row level security;
alter table follows enable row level security;
alter table notifications enable row level security;
