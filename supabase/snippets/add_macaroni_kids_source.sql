INSERT INTO public.event_sources (name, url, source_type, city_id, is_active, scrape_interval_hours, date_window_days, notes)
SELECT 'Macaroni Kid Lafayette',
       'https://lafayettela.macaronikid.com/events',
       'macaronikid', c.id, true, 12, 90,
       'JSON API; two-hop fetch.'
FROM public.cities c WHERE c.slug='lafayette';