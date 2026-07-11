
-- =========================
-- ENUMS
-- =========================
create type public.app_role as enum ('admin','moderator','user');
create type public.post_status as enum ('draft','published','archived','removed');
create type public.report_status as enum ('open','reviewing','resolved','rejected');
create type public.notif_type as enum ('vote','comment','follow','achievement','reward','announcement','system','report');

-- =========================
-- PROFILES
-- =========================
create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  username text unique not null,
  display_name text,
  bio text,
  avatar_url text,
  cover_url text,
  location text,
  website text,
  xp integer not null default 0,
  coins integer not null default 0,
  gems integer not null default 0,
  level integer not null default 1,
  prestige integer not null default 0,
  streak_days integer not null default 0,
  last_login_at timestamptz,
  verified boolean not null default false,
  banned boolean not null default false,
  suspended_until timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
grant select on public.profiles to anon;
grant select, insert, update, delete on public.profiles to authenticated;
grant all on public.profiles to service_role;
alter table public.profiles enable row level security;
create policy "profiles are viewable by everyone" on public.profiles for select using (true);
create policy "users update own profile" on public.profiles for update using (auth.uid() = id) with check (auth.uid() = id);
create policy "users insert own profile" on public.profiles for insert with check (auth.uid() = id);

-- =========================
-- USER ROLES
-- =========================
create table public.user_roles (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  role public.app_role not null,
  created_at timestamptz not null default now(),
  unique (user_id, role)
);
grant select on public.user_roles to authenticated;
grant all on public.user_roles to service_role;
alter table public.user_roles enable row level security;

create or replace function public.has_role(_user_id uuid, _role public.app_role)
returns boolean language sql stable security definer set search_path = public as $$
  select exists(select 1 from public.user_roles where user_id = _user_id and role = _role);
$$;

create policy "users view own roles" on public.user_roles for select using (auth.uid() = user_id);
create policy "admins view all roles" on public.user_roles for select using (public.has_role(auth.uid(),'admin'));
create policy "admins manage roles" on public.user_roles for all using (public.has_role(auth.uid(),'admin')) with check (public.has_role(auth.uid(),'admin'));

-- =========================
-- HANDLE NEW USER (profile + role + admin-email promotion)
-- =========================
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  base_username text;
  final_username text;
  i int := 0;
begin
  base_username := coalesce(new.raw_user_meta_data->>'username', split_part(new.email,'@',1), 'user');
  base_username := regexp_replace(lower(base_username),'[^a-z0-9_]','','g');
  if length(base_username) < 3 then base_username := 'user' || substr(new.id::text,1,6); end if;
  final_username := base_username;
  while exists(select 1 from public.profiles where username = final_username) loop
    i := i + 1;
    final_username := base_username || i::text;
  end loop;

  insert into public.profiles(id, username, display_name, avatar_url)
  values(new.id, final_username,
         coalesce(new.raw_user_meta_data->>'display_name', base_username),
         new.raw_user_meta_data->>'avatar_url');

  insert into public.user_roles(user_id, role) values(new.id, 'user') on conflict do nothing;
  return new;
end $$;

create trigger on_auth_user_created after insert on auth.users
for each row execute function public.handle_new_user();

-- Auto-promote verified admin email
create or replace function public.grant_admin_for_verified_email()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.email_confirmed_at is not null and lower(new.email) = 'abhijeetmajik@gmail.com' then
    insert into public.user_roles(user_id, role) values(new.id, 'admin') on conflict do nothing;
    update public.profiles set verified = true where id = new.id;
  end if;
  return new;
end $$;
create trigger on_auth_user_created_admin after insert on auth.users
for each row execute function public.grant_admin_for_verified_email();
create trigger on_auth_user_confirmed_admin after update of email_confirmed_at on auth.users
for each row when (old.email_confirmed_at is null and new.email_confirmed_at is not null)
execute function public.grant_admin_for_verified_email();

-- =========================
-- CATEGORIES
-- =========================
create table public.categories (
  id uuid primary key default gen_random_uuid(),
  slug text unique not null,
  name text not null,
  description text,
  icon text,
  color text,
  sort_order int not null default 0,
  created_at timestamptz not null default now()
);
grant select on public.categories to anon, authenticated;
grant all on public.categories to service_role;
alter table public.categories enable row level security;
create policy "categories viewable by all" on public.categories for select using (true);
create policy "admins manage categories" on public.categories for all using (public.has_role(auth.uid(),'admin')) with check (public.has_role(auth.uid(),'admin'));

insert into public.categories(slug,name,icon,color,sort_order) values
('nature','Nature','🌲','#22c55e',1),
('urban','Urban','🏙️','#7c3aed',2),
('beach','Beach','🏖️','#22d3ee',3),
('mountains','Mountains','⛰️','#f59e0b',4),
('food','Food Spots','🍜','#ef4444',5),
('history','Historic','🏛️','#a78bfa',6),
('nightlife','Nightlife','🌃','#ec4899',7),
('hidden','Hidden Gems','💎','#10b981',8),
('adventure','Adventure','🎒','#f97316',9),
('art','Street Art','🎨','#8b5cf6',10);

-- =========================
-- POSTS
-- =========================
create table public.posts (
  id uuid primary key default gen_random_uuid(),
  author_id uuid not null references auth.users(id) on delete cascade,
  category_id uuid references public.categories(id) on delete set null,
  title text not null check (length(title) between 3 and 140),
  description text check (length(description) <= 3000),
  cover_url text,
  tags text[] not null default '{}',
  latitude double precision,
  longitude double precision,
  location_name text,
  city text,
  state text,
  country text,
  status public.post_status not null default 'published',
  vote_count integer not null default 0,
  comment_count integer not null default 0,
  view_count integer not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index posts_created_idx on public.posts(created_at desc);
create index posts_votes_idx on public.posts(vote_count desc);
create index posts_category_idx on public.posts(category_id);
create index posts_author_idx on public.posts(author_id);
grant select on public.posts to anon;
grant select, insert, update, delete on public.posts to authenticated;
grant all on public.posts to service_role;
alter table public.posts enable row level security;
create policy "published posts viewable by all" on public.posts for select using (status = 'published' or auth.uid() = author_id or public.has_role(auth.uid(),'admin'));
create policy "authors insert own posts" on public.posts for insert with check (auth.uid() = author_id);
create policy "authors update own posts" on public.posts for update using (auth.uid() = author_id or public.has_role(auth.uid(),'admin')) with check (auth.uid() = author_id or public.has_role(auth.uid(),'admin'));
create policy "authors delete own posts" on public.posts for delete using (auth.uid() = author_id or public.has_role(auth.uid(),'admin'));

-- POST IMAGES
create table public.post_images (
  id uuid primary key default gen_random_uuid(),
  post_id uuid not null references public.posts(id) on delete cascade,
  url text not null,
  sort_order int not null default 0,
  created_at timestamptz not null default now()
);
create index post_images_post_idx on public.post_images(post_id);
grant select on public.post_images to anon, authenticated;
grant insert, update, delete on public.post_images to authenticated;
grant all on public.post_images to service_role;
alter table public.post_images enable row level security;
create policy "post images viewable by all" on public.post_images for select using (true);
create policy "authors manage own post images" on public.post_images for all
  using (exists(select 1 from public.posts p where p.id = post_id and (p.author_id = auth.uid() or public.has_role(auth.uid(),'admin'))))
  with check (exists(select 1 from public.posts p where p.id = post_id and (p.author_id = auth.uid() or public.has_role(auth.uid(),'admin'))));

-- =========================
-- VOTES
-- =========================
create table public.votes (
  id uuid primary key default gen_random_uuid(),
  post_id uuid not null references public.posts(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  created_at timestamptz not null default now(),
  unique(post_id, user_id)
);
create index votes_post_idx on public.votes(post_id);
create index votes_user_idx on public.votes(user_id);
create index votes_created_idx on public.votes(created_at desc);
grant select on public.votes to anon, authenticated;
grant insert, delete on public.votes to authenticated;
grant all on public.votes to service_role;
alter table public.votes enable row level security;
create policy "votes viewable by all" on public.votes for select using (true);
create policy "users vote once" on public.votes for insert with check (auth.uid() = user_id);
create policy "users remove own vote" on public.votes for delete using (auth.uid() = user_id);

-- Vote count trigger + notification + xp
create or replace function public.on_vote_change()
returns trigger language plpgsql security definer set search_path = public as $$
declare _author uuid;
begin
  if TG_OP = 'INSERT' then
    update public.posts set vote_count = vote_count + 1 where id = new.post_id
      returning author_id into _author;
    if _author is not null and _author <> new.user_id then
      insert into public.notifications(user_id, actor_id, type, post_id, message)
      values(_author, new.user_id, 'vote', new.post_id, 'voted for your post');
      update public.profiles set xp = xp + 2 where id = _author;
      update public.profiles set xp = xp + 1, coins = coins + 1 where id = new.user_id;
    end if;
    return new;
  elsif TG_OP = 'DELETE' then
    update public.posts set vote_count = greatest(vote_count - 1, 0) where id = old.post_id;
    return old;
  end if;
  return null;
end $$;
create trigger votes_after_insert after insert on public.votes for each row execute function public.on_vote_change();
create trigger votes_after_delete after delete on public.votes for each row execute function public.on_vote_change();

-- =========================
-- COMMENTS
-- =========================
create table public.comments (
  id uuid primary key default gen_random_uuid(),
  post_id uuid not null references public.posts(id) on delete cascade,
  author_id uuid not null references auth.users(id) on delete cascade,
  parent_id uuid references public.comments(id) on delete cascade,
  body text not null check (length(body) between 1 and 2000),
  like_count int not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index comments_post_idx on public.comments(post_id, created_at desc);
grant select on public.comments to anon, authenticated;
grant insert, update, delete on public.comments to authenticated;
grant all on public.comments to service_role;
alter table public.comments enable row level security;
create policy "comments viewable by all" on public.comments for select using (true);
create policy "users create comments" on public.comments for insert with check (auth.uid() = author_id);
create policy "users update own comments" on public.comments for update using (auth.uid() = author_id) with check (auth.uid() = author_id);
create policy "users delete own comments or admin" on public.comments for delete using (auth.uid() = author_id or public.has_role(auth.uid(),'admin'));

create or replace function public.on_comment_change()
returns trigger language plpgsql security definer set search_path = public as $$
declare _author uuid;
begin
  if TG_OP = 'INSERT' then
    update public.posts set comment_count = comment_count + 1 where id = new.post_id
      returning author_id into _author;
    if _author is not null and _author <> new.author_id then
      insert into public.notifications(user_id, actor_id, type, post_id, message)
      values(_author, new.author_id, 'comment', new.post_id, 'commented on your post');
    end if;
    update public.profiles set xp = xp + 3 where id = new.author_id;
    return new;
  elsif TG_OP = 'DELETE' then
    update public.posts set comment_count = greatest(comment_count - 1, 0) where id = old.post_id;
    return old;
  end if;
  return null;
end $$;
create trigger comments_after_insert after insert on public.comments for each row execute function public.on_comment_change();
create trigger comments_after_delete after delete on public.comments for each row execute function public.on_comment_change();

-- =========================
-- FOLLOWS
-- =========================
create table public.follows (
  follower_id uuid not null references auth.users(id) on delete cascade,
  following_id uuid not null references auth.users(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (follower_id, following_id),
  check (follower_id <> following_id)
);
grant select on public.follows to anon, authenticated;
grant insert, delete on public.follows to authenticated;
grant all on public.follows to service_role;
alter table public.follows enable row level security;
create policy "follows viewable by all" on public.follows for select using (true);
create policy "users follow" on public.follows for insert with check (auth.uid() = follower_id);
create policy "users unfollow" on public.follows for delete using (auth.uid() = follower_id);

create or replace function public.on_follow_insert()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.notifications(user_id, actor_id, type, message)
  values(new.following_id, new.follower_id, 'follow', 'started following you');
  return new;
end $$;
create trigger follows_after_insert after insert on public.follows for each row execute function public.on_follow_insert();

-- =========================
-- NOTIFICATIONS
-- =========================
create table public.notifications (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  actor_id uuid references auth.users(id) on delete set null,
  type public.notif_type not null,
  post_id uuid references public.posts(id) on delete cascade,
  message text,
  read boolean not null default false,
  created_at timestamptz not null default now()
);
create index notif_user_idx on public.notifications(user_id, created_at desc);
grant select, update, delete on public.notifications to authenticated;
grant all on public.notifications to service_role;
alter table public.notifications enable row level security;
create policy "users read own notifs" on public.notifications for select using (auth.uid() = user_id);
create policy "users update own notifs" on public.notifications for update using (auth.uid() = user_id) with check (auth.uid() = user_id);
create policy "users delete own notifs" on public.notifications for delete using (auth.uid() = user_id);

-- =========================
-- BOOKMARKS
-- =========================
create table public.bookmarks (
  user_id uuid not null references auth.users(id) on delete cascade,
  post_id uuid not null references public.posts(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (user_id, post_id)
);
grant select, insert, delete on public.bookmarks to authenticated;
grant all on public.bookmarks to service_role;
alter table public.bookmarks enable row level security;
create policy "users see own bookmarks" on public.bookmarks for select using (auth.uid() = user_id);
create policy "users add own bookmarks" on public.bookmarks for insert with check (auth.uid() = user_id);
create policy "users remove own bookmarks" on public.bookmarks for delete using (auth.uid() = user_id);

-- =========================
-- REPORTS
-- =========================
create table public.reports (
  id uuid primary key default gen_random_uuid(),
  reporter_id uuid not null references auth.users(id) on delete cascade,
  post_id uuid references public.posts(id) on delete cascade,
  comment_id uuid references public.comments(id) on delete cascade,
  reason text not null,
  details text,
  status public.report_status not null default 'open',
  created_at timestamptz not null default now()
);
grant select, insert on public.reports to authenticated;
grant all on public.reports to service_role;
alter table public.reports enable row level security;
create policy "reporters see own" on public.reports for select using (auth.uid() = reporter_id or public.has_role(auth.uid(),'admin') or public.has_role(auth.uid(),'moderator'));
create policy "users file report" on public.reports for insert with check (auth.uid() = reporter_id);
create policy "admins manage reports" on public.reports for update using (public.has_role(auth.uid(),'admin') or public.has_role(auth.uid(),'moderator')) with check (true);

-- =========================
-- ACHIEVEMENTS
-- =========================
create table public.achievements (
  id uuid primary key default gen_random_uuid(),
  code text unique not null,
  name text not null,
  description text,
  icon text,
  xp_reward int not null default 0,
  coin_reward int not null default 0,
  hidden boolean not null default false,
  created_at timestamptz not null default now()
);
grant select on public.achievements to anon, authenticated;
grant all on public.achievements to service_role;
alter table public.achievements enable row level security;
create policy "achievements viewable" on public.achievements for select using (true);
create policy "admins manage achievements" on public.achievements for all using (public.has_role(auth.uid(),'admin')) with check (public.has_role(auth.uid(),'admin'));

insert into public.achievements(code,name,description,icon,xp_reward,coin_reward,hidden) values
('first_upload','First Steps','Uploaded your first location','🚀',50,10,false),
('first_vote','Voter','Cast your first vote','👍',20,5,false),
('ten_posts','Explorer','10 locations shared','🗺️',200,50,false),
('hundred_posts','Cartographer','100 locations shared','📍',1000,300,false),
('thousand_votes','Kingmaker','1000 votes cast','👑',500,150,false),
('daily_winner','Champion of the Day','Won a daily leaderboard','🏆',300,100,false),
('weekly_winner','Weekly Legend','Won a weekly leaderboard','🥇',800,250,false),
('community_hero','Community Hero','Helped 50 people','💛',400,120,false),
('diamond','Diamond Member','Reached level 50','💎',2000,500,false),
('legend','Legend','Reached prestige 1','🌟',5000,1000,true),
('top_contributor','Top Contributor','Made the Hall of Fame','🏛️',1500,400,false),
('night_owl','Night Owl','Posted between 12am–5am','🦉',75,20,true),
('streak_7','Week Warrior','7-day login streak','🔥',150,30,false),
('streak_30','Unstoppable','30-day login streak','⚡',700,200,false),
('first_follower','Popular','First follower','🎉',30,10,false),
('social_butterfly','Social Butterfly','100 followers','🦋',500,150,false);

create table public.user_achievements (
  user_id uuid not null references auth.users(id) on delete cascade,
  achievement_id uuid not null references public.achievements(id) on delete cascade,
  earned_at timestamptz not null default now(),
  primary key (user_id, achievement_id)
);
grant select on public.user_achievements to anon, authenticated;
grant insert on public.user_achievements to authenticated;
grant all on public.user_achievements to service_role;
alter table public.user_achievements enable row level security;
create policy "achievements progress viewable" on public.user_achievements for select using (true);
create policy "users earn own" on public.user_achievements for insert with check (auth.uid() = user_id);

-- =========================
-- XP EVENTS / DAILY REWARDS / STREAKS
-- =========================
create table public.xp_events (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  amount int not null,
  reason text not null,
  created_at timestamptz not null default now()
);
grant select on public.xp_events to authenticated;
grant insert on public.xp_events to authenticated;
grant all on public.xp_events to service_role;
alter table public.xp_events enable row level security;
create policy "users see own xp" on public.xp_events for select using (auth.uid() = user_id);
create policy "users log own xp" on public.xp_events for insert with check (auth.uid() = user_id);

create table public.daily_rewards (
  user_id uuid not null references auth.users(id) on delete cascade,
  claimed_date date not null,
  coins int not null default 10,
  xp int not null default 20,
  primary key (user_id, claimed_date)
);
grant select, insert on public.daily_rewards to authenticated;
grant all on public.daily_rewards to service_role;
alter table public.daily_rewards enable row level security;
create policy "users see own daily" on public.daily_rewards for select using (auth.uid() = user_id);
create policy "users claim own daily" on public.daily_rewards for insert with check (auth.uid() = user_id);

-- =========================
-- MISSIONS
-- =========================
create table public.missions (
  id uuid primary key default gen_random_uuid(),
  code text unique not null,
  title text not null,
  description text,
  goal int not null default 1,
  xp_reward int not null default 50,
  coin_reward int not null default 10,
  active boolean not null default true,
  created_at timestamptz not null default now()
);
grant select on public.missions to anon, authenticated;
grant all on public.missions to service_role;
alter table public.missions enable row level security;
create policy "missions viewable" on public.missions for select using (true);
create policy "admins manage missions" on public.missions for all using (public.has_role(auth.uid(),'admin')) with check (public.has_role(auth.uid(),'admin'));

insert into public.missions(code,title,description,goal,xp_reward,coin_reward) values
('post_1','Share a Location','Upload a new location today',1,50,15),
('vote_5','Support Explorers','Vote for 5 posts today',5,40,10),
('comment_3','Start a Convo','Leave 3 comments today',3,30,10),
('bookmark_3','Save Favorites','Bookmark 3 posts',3,20,5);

create table public.user_missions (
  user_id uuid not null references auth.users(id) on delete cascade,
  mission_id uuid not null references public.missions(id) on delete cascade,
  progress int not null default 0,
  completed_at timestamptz,
  reset_date date not null default current_date,
  primary key (user_id, mission_id, reset_date)
);
grant select, insert, update on public.user_missions to authenticated;
grant all on public.user_missions to service_role;
alter table public.user_missions enable row level security;
create policy "users see own missions" on public.user_missions for select using (auth.uid() = user_id);
create policy "users track own missions" on public.user_missions for insert with check (auth.uid() = user_id);
create policy "users update own missions" on public.user_missions for update using (auth.uid() = user_id) with check (auth.uid() = user_id);

-- =========================
-- ANNOUNCEMENTS
-- =========================
create table public.announcements (
  id uuid primary key default gen_random_uuid(),
  title text not null,
  body text not null,
  pinned boolean not null default false,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now()
);
grant select on public.announcements to anon, authenticated;
grant all on public.announcements to service_role;
alter table public.announcements enable row level security;
create policy "announcements viewable" on public.announcements for select using (true);
create policy "admins write announcements" on public.announcements for all using (public.has_role(auth.uid(),'admin')) with check (public.has_role(auth.uid(),'admin'));

-- =========================
-- STORAGE POLICIES for avatars, covers, post-images
-- =========================
create policy "public read avatars" on storage.objects for select using (bucket_id = 'avatars');
create policy "auth upload avatars" on storage.objects for insert to authenticated with check (bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text);
create policy "auth update own avatars" on storage.objects for update to authenticated using (bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text);
create policy "auth delete own avatars" on storage.objects for delete to authenticated using (bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text);

create policy "public read covers" on storage.objects for select using (bucket_id = 'covers');
create policy "auth upload covers" on storage.objects for insert to authenticated with check (bucket_id = 'covers' and (storage.foldername(name))[1] = auth.uid()::text);
create policy "auth update own covers" on storage.objects for update to authenticated using (bucket_id = 'covers' and (storage.foldername(name))[1] = auth.uid()::text);
create policy "auth delete own covers" on storage.objects for delete to authenticated using (bucket_id = 'covers' and (storage.foldername(name))[1] = auth.uid()::text);

create policy "public read post-images" on storage.objects for select using (bucket_id = 'post-images');
create policy "auth upload post-images" on storage.objects for insert to authenticated with check (bucket_id = 'post-images' and (storage.foldername(name))[1] = auth.uid()::text);
create policy "auth update own post-images" on storage.objects for update to authenticated using (bucket_id = 'post-images' and (storage.foldername(name))[1] = auth.uid()::text);
create policy "auth delete own post-images" on storage.objects for delete to authenticated using (bucket_id = 'post-images' and (storage.foldername(name))[1] = auth.uid()::text);

-- =========================
-- LEADERBOARD VIEWS
-- =========================
create or replace view public.leaderboard_daily as
select p.id as post_id, p.title, p.cover_url, p.author_id, pr.username, pr.avatar_url,
       count(v.*) as votes
from public.posts p
left join public.votes v on v.post_id = p.id and v.created_at >= date_trunc('day', now())
left join public.profiles pr on pr.id = p.author_id
where p.status = 'published'
group by p.id, pr.username, pr.avatar_url
order by votes desc, p.created_at desc;

create or replace view public.leaderboard_weekly as
select p.id as post_id, p.title, p.cover_url, p.author_id, pr.username, pr.avatar_url,
       count(v.*) as votes
from public.posts p
left join public.votes v on v.post_id = p.id and v.created_at >= date_trunc('week', now())
left join public.profiles pr on pr.id = p.author_id
where p.status = 'published'
group by p.id, pr.username, pr.avatar_url
order by votes desc, p.created_at desc;

create or replace view public.leaderboard_monthly as
select p.id as post_id, p.title, p.cover_url, p.author_id, pr.username, pr.avatar_url,
       count(v.*) as votes
from public.posts p
left join public.votes v on v.post_id = p.id and v.created_at >= date_trunc('month', now())
left join public.profiles pr on pr.id = p.author_id
where p.status = 'published'
group by p.id, pr.username, pr.avatar_url
order by votes desc, p.created_at desc;

create or replace view public.leaderboard_global as
select p.id as post_id, p.title, p.cover_url, p.author_id, pr.username, pr.avatar_url,
       p.vote_count as votes
from public.posts p
left join public.profiles pr on pr.id = p.author_id
where p.status = 'published'
order by p.vote_count desc, p.created_at desc;

create or replace view public.top_users as
select pr.id, pr.username, pr.display_name, pr.avatar_url, pr.xp, pr.level, pr.coins,
       (select count(*) from public.posts where author_id = pr.id and status='published') as posts_count,
       (select count(*) from public.follows where following_id = pr.id) as followers_count
from public.profiles pr
order by pr.xp desc;

grant select on public.leaderboard_daily, public.leaderboard_weekly, public.leaderboard_monthly, public.leaderboard_global, public.top_users to anon, authenticated;

-- =========================
-- REALTIME
-- =========================
alter publication supabase_realtime add table public.votes;
alter publication supabase_realtime add table public.notifications;
alter publication supabase_realtime add table public.comments;
alter publication supabase_realtime add table public.posts;
