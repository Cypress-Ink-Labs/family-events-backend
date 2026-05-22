DO $$
DECLARE
  lafayette_city_id uuid;
  existing_lpl_id uuid;
  existing_correct_id uuid;
  correct_url text := 'https://lafayettela.libcal.com/ical_subscribe.php?src=p&cid=11334';
BEGIN
  SELECT id
  INTO lafayette_city_id
  FROM public.cities
  WHERE slug = 'lafayette';

  SELECT id
  INTO existing_correct_id
  FROM public.event_sources
  WHERE url = correct_url
  ORDER BY created_at
  LIMIT 1;

  SELECT id
  INTO existing_lpl_id
  FROM public.event_sources
  WHERE name = 'Lafayette Public Library'
  ORDER BY created_at
  LIMIT 1;

  IF existing_lpl_id IS NOT NULL AND existing_correct_id IS NULL THEN
    UPDATE public.event_sources
    SET
      url = correct_url,
      source_type = 'ical',
      city_id = lafayette_city_id,
      scrape_interval_hours = 6,
      date_window_days = NULL,
      notes = 'Library story times and kids programming via LibCal iCal feed',
      updated_at = now()
    WHERE id = existing_lpl_id;
  ELSIF existing_correct_id IS NOT NULL THEN
    UPDATE public.event_sources
    SET
      name = 'Lafayette Public Library',
      source_type = 'ical',
      city_id = lafayette_city_id,
      is_active = true,
      scrape_interval_hours = 6,
      date_window_days = NULL,
      notes = 'Library story times and kids programming via LibCal iCal feed',
      updated_at = now()
    WHERE id = existing_correct_id;

    UPDATE public.event_sources
    SET
      is_active = false,
      notes = 'Replaced by Lafayette Public Library LibCal iCal feed.',
      updated_at = now()
    WHERE name = 'Lafayette Public Library'
      AND id <> existing_correct_id;
  ELSE
    INSERT INTO public.event_sources (
      name,
      url,
      source_type,
      city_id,
      is_active,
      scrape_interval_hours,
      date_window_days,
      notes
    )
    VALUES (
      'Lafayette Public Library',
      correct_url,
      'ical',
      lafayette_city_id,
      true,
      6,
      NULL,
      'Library story times and kids programming via LibCal iCal feed'
    );
  END IF;
END $$;
