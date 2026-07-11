
alter view public.leaderboard_daily set (security_invoker = true);
alter view public.leaderboard_weekly set (security_invoker = true);
alter view public.leaderboard_monthly set (security_invoker = true);
alter view public.leaderboard_global set (security_invoker = true);
alter view public.top_users set (security_invoker = true);
