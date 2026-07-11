
alter table public.posts add constraint posts_author_profile_fkey foreign key (author_id) references public.profiles(id) on delete cascade;
alter table public.comments add constraint comments_author_profile_fkey foreign key (author_id) references public.profiles(id) on delete cascade;
alter table public.notifications add constraint notifications_actor_profile_fkey foreign key (actor_id) references public.profiles(id) on delete set null;
alter table public.follows add constraint follows_follower_profile_fkey foreign key (follower_id) references public.profiles(id) on delete cascade;
alter table public.follows add constraint follows_following_profile_fkey foreign key (following_id) references public.profiles(id) on delete cascade;
