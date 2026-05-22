export type Json =
  | string
  | number
  | boolean
  | null
  | { [key: string]: Json | undefined }
  | Json[]

export type Database = {
  // Allows to automatically instantiate createClient with right options
  // instead of createClient<Database, { PostgrestVersion: 'XX' }>(URL, KEY)
  __InternalSupabase: {
    PostgrestVersion: "14.5"
  }
  public: {
    Tables: {
      admin_audit_log: {
        Row: {
          action: string
          admin_user_id: string | null
          created_at: string
          id: string
          metadata: Json | null
          target_id: string | null
          target_type: string | null
        }
        Insert: {
          action: string
          admin_user_id?: string | null
          created_at?: string
          id?: string
          metadata?: Json | null
          target_id?: string | null
          target_type?: string | null
        }
        Update: {
          action?: string
          admin_user_id?: string | null
          created_at?: string
          id?: string
          metadata?: Json | null
          target_id?: string | null
          target_type?: string | null
        }
        Relationships: []
      }
      cities: {
        Row: {
          country: string
          created_at: string
          id: string
          is_active: boolean
          latitude: number | null
          longitude: number | null
          name: string
          slug: string
          state: string | null
          timezone: string
        }
        Insert: {
          country?: string
          created_at?: string
          id?: string
          is_active?: boolean
          latitude?: number | null
          longitude?: number | null
          name: string
          slug: string
          state?: string | null
          timezone?: string
        }
        Update: {
          country?: string
          created_at?: string
          id?: string
          is_active?: boolean
          latitude?: number | null
          longitude?: number | null
          name?: string
          slug?: string
          state?: string | null
          timezone?: string
        }
        Relationships: []
      }
      comments: {
        Row: {
          body: string
          created_at: string
          event_id: string
          id: string
          is_approved: boolean
          is_flagged: boolean
          updated_at: string
          user_id: string
        }
        Insert: {
          body: string
          created_at?: string
          event_id: string
          id?: string
          is_approved?: boolean
          is_flagged?: boolean
          updated_at?: string
          user_id: string
        }
        Update: {
          body?: string
          created_at?: string
          event_id?: string
          id?: string
          is_approved?: boolean
          is_flagged?: boolean
          updated_at?: string
          user_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "comments_event_id_fkey"
            columns: ["event_id"]
            isOneToOne: false
            referencedRelation: "events"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "comments_event_id_fkey"
            columns: ["event_id"]
            isOneToOne: false
            referencedRelation: "public_events"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "comments_user_id_fkey"
            columns: ["user_id"]
            isOneToOne: false
            referencedRelation: "user_profiles"
            referencedColumns: ["id"]
          },
        ]
      }
      event_ai_traces: {
        Row: {
          available_tag_slugs: Json
          created_at: string
          event_id: string
          fallback_reason: string | null
          id: string
          input_description: string | null
          input_title: string
          model: string | null
          predicted_fields: Json | null
          predicted_tags: Json
          processing_ms: number | null
          provider: string | null
          reasoning_summary: string | null
          source_run_id: string | null
          status: string
          trigger_type: string
        }
        Insert: {
          available_tag_slugs?: Json
          created_at?: string
          event_id: string
          fallback_reason?: string | null
          id?: string
          input_description?: string | null
          input_title: string
          model?: string | null
          predicted_fields?: Json | null
          predicted_tags?: Json
          processing_ms?: number | null
          provider?: string | null
          reasoning_summary?: string | null
          source_run_id?: string | null
          status?: string
          trigger_type?: string
        }
        Update: {
          available_tag_slugs?: Json
          created_at?: string
          event_id?: string
          fallback_reason?: string | null
          id?: string
          input_description?: string | null
          input_title?: string
          model?: string | null
          predicted_fields?: Json | null
          predicted_tags?: Json
          processing_ms?: number | null
          provider?: string | null
          reasoning_summary?: string | null
          source_run_id?: string | null
          status?: string
          trigger_type?: string
        }
        Relationships: [
          {
            foreignKeyName: "event_ai_traces_event_id_fkey"
            columns: ["event_id"]
            isOneToOne: false
            referencedRelation: "events"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "event_ai_traces_event_id_fkey"
            columns: ["event_id"]
            isOneToOne: false
            referencedRelation: "public_events"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "event_ai_traces_source_run_id_fkey"
            columns: ["source_run_id"]
            isOneToOne: false
            referencedRelation: "source_runs"
            referencedColumns: ["id"]
          },
        ]
      }
      event_sources: {
        Row: {
          auto_approve: boolean
          city_id: string | null
          created_at: string
          date_window_days: number | null
          error_count: number
          extraction_mode: Database["public"]["Enums"]["source_extraction_mode"]
          id: string
          is_active: boolean
          last_scraped_at: string | null
          last_status: string | null
          name: string
          notes: string | null
          scrape_interval_hours: number
          source_type: string
          updated_at: string
          url: string
        }
        Insert: {
          auto_approve?: boolean
          city_id?: string | null
          created_at?: string
          date_window_days?: number | null
          error_count?: number
          extraction_mode?: Database["public"]["Enums"]["source_extraction_mode"]
          id?: string
          is_active?: boolean
          last_scraped_at?: string | null
          last_status?: string | null
          name: string
          notes?: string | null
          scrape_interval_hours?: number
          source_type?: string
          updated_at?: string
          url: string
        }
        Update: {
          auto_approve?: boolean
          city_id?: string | null
          created_at?: string
          date_window_days?: number | null
          error_count?: number
          extraction_mode?: Database["public"]["Enums"]["source_extraction_mode"]
          id?: string
          is_active?: boolean
          last_scraped_at?: string | null
          last_status?: string | null
          name?: string
          notes?: string | null
          scrape_interval_hours?: number
          source_type?: string
          updated_at?: string
          url?: string
        }
        Relationships: [
          {
            foreignKeyName: "event_sources_city_id_fkey"
            columns: ["city_id"]
            isOneToOne: false
            referencedRelation: "cities"
            referencedColumns: ["id"]
          },
        ]
      }
      event_tag_queue: {
        Row: {
          attempt_count: number
          enqueued_at: string
          event_id: string
          finished_at: string | null
          id: number
          last_error: string | null
          next_attempt_at: string
          source_run_id: string | null
          started_at: string | null
          status: Database["public"]["Enums"]["event_tag_queue_status"]
          trigger_type: string
        }
        Insert: {
          attempt_count?: number
          enqueued_at?: string
          event_id: string
          finished_at?: string | null
          id?: never
          last_error?: string | null
          next_attempt_at?: string
          source_run_id?: string | null
          started_at?: string | null
          status?: Database["public"]["Enums"]["event_tag_queue_status"]
          trigger_type?: string
        }
        Update: {
          attempt_count?: number
          enqueued_at?: string
          event_id?: string
          finished_at?: string | null
          id?: never
          last_error?: string | null
          next_attempt_at?: string
          source_run_id?: string | null
          started_at?: string | null
          status?: Database["public"]["Enums"]["event_tag_queue_status"]
          trigger_type?: string
        }
        Relationships: [
          {
            foreignKeyName: "event_tag_queue_event_id_fkey"
            columns: ["event_id"]
            isOneToOne: false
            referencedRelation: "events"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "event_tag_queue_event_id_fkey"
            columns: ["event_id"]
            isOneToOne: false
            referencedRelation: "public_events"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "event_tag_queue_source_run_id_fkey"
            columns: ["source_run_id"]
            isOneToOne: false
            referencedRelation: "source_runs"
            referencedColumns: ["id"]
          },
        ]
      }
      event_tags: {
        Row: {
          confidence: number
          created_at: string
          event_id: string
          is_manual_override: boolean
          tag_id: string
        }
        Insert: {
          confidence?: number
          created_at?: string
          event_id: string
          is_manual_override?: boolean
          tag_id: string
        }
        Update: {
          confidence?: number
          created_at?: string
          event_id?: string
          is_manual_override?: boolean
          tag_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "event_tags_event_id_fkey"
            columns: ["event_id"]
            isOneToOne: false
            referencedRelation: "events"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "event_tags_event_id_fkey"
            columns: ["event_id"]
            isOneToOne: false
            referencedRelation: "public_events"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "event_tags_tag_id_fkey"
            columns: ["tag_id"]
            isOneToOne: false
            referencedRelation: "tags"
            referencedColumns: ["id"]
          },
        ]
      }
      events: {
        Row: {
          address: string | null
          admin_last_edited_at: string | null
          admin_last_edited_by: string | null
          admin_locked_fields: string[]
          age_max: number | null
          age_min: number | null
          ai_confidence: number | null
          ai_tag_model: string | null
          ai_tag_provider: string | null
          ai_tag_status: string | null
          city_id: string | null
          created_at: string
          description: string | null
          end_datetime: string | null
          id: string
          images: Json
          is_featured: boolean
          is_free: boolean
          is_outdoor: boolean | null
          latitude: number | null
          longitude: number | null
          price: number | null
          recurrence_info: Json | null
          search_vector: unknown
          source_id: string | null
          source_name: string | null
          source_url: string | null
          start_datetime: string
          status: string
          timezone: string
          title: string
          updated_at: string
          venue_name: string | null
          view_count: number
        }
        Insert: {
          address?: string | null
          admin_last_edited_at?: string | null
          admin_last_edited_by?: string | null
          admin_locked_fields?: string[]
          age_max?: number | null
          age_min?: number | null
          ai_confidence?: number | null
          ai_tag_model?: string | null
          ai_tag_provider?: string | null
          ai_tag_status?: string | null
          city_id?: string | null
          created_at?: string
          description?: string | null
          end_datetime?: string | null
          id?: string
          images?: Json
          is_featured?: boolean
          is_free?: boolean
          is_outdoor?: boolean | null
          latitude?: number | null
          longitude?: number | null
          price?: number | null
          recurrence_info?: Json | null
          search_vector?: unknown
          source_id?: string | null
          source_name?: string | null
          source_url?: string | null
          start_datetime: string
          status?: string
          timezone?: string
          title: string
          updated_at?: string
          venue_name?: string | null
          view_count?: number
        }
        Update: {
          address?: string | null
          admin_last_edited_at?: string | null
          admin_last_edited_by?: string | null
          admin_locked_fields?: string[]
          age_max?: number | null
          age_min?: number | null
          ai_confidence?: number | null
          ai_tag_model?: string | null
          ai_tag_provider?: string | null
          ai_tag_status?: string | null
          city_id?: string | null
          created_at?: string
          description?: string | null
          end_datetime?: string | null
          id?: string
          images?: Json
          is_featured?: boolean
          is_free?: boolean
          is_outdoor?: boolean | null
          latitude?: number | null
          longitude?: number | null
          price?: number | null
          recurrence_info?: Json | null
          search_vector?: unknown
          source_id?: string | null
          source_name?: string | null
          source_url?: string | null
          start_datetime?: string
          status?: string
          timezone?: string
          title?: string
          updated_at?: string
          venue_name?: string | null
          view_count?: number
        }
        Relationships: [
          {
            foreignKeyName: "events_city_id_fkey"
            columns: ["city_id"]
            isOneToOne: false
            referencedRelation: "cities"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "events_source_id_fkey"
            columns: ["source_id"]
            isOneToOne: false
            referencedRelation: "event_sources"
            referencedColumns: ["id"]
          },
        ]
      }
      favorites: {
        Row: {
          created_at: string
          event_id: string
          id: string
          user_id: string
        }
        Insert: {
          created_at?: string
          event_id: string
          id?: string
          user_id: string
        }
        Update: {
          created_at?: string
          event_id?: string
          id?: string
          user_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "favorites_event_id_fkey"
            columns: ["event_id"]
            isOneToOne: false
            referencedRelation: "events"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "favorites_event_id_fkey"
            columns: ["event_id"]
            isOneToOne: false
            referencedRelation: "public_events"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "favorites_user_id_fkey"
            columns: ["user_id"]
            isOneToOne: false
            referencedRelation: "user_profiles"
            referencedColumns: ["id"]
          },
        ]
      }
      invite_codes: {
        Row: {
          code_hash: string
          created_at: string
          created_by: string | null
          expires_at: string | null
          id: string
          max_uses: number
          notes: string | null
          revoked_at: string | null
          used_count: number
        }
        Insert: {
          code_hash: string
          created_at?: string
          created_by?: string | null
          expires_at?: string | null
          id?: string
          max_uses?: number
          notes?: string | null
          revoked_at?: string | null
          used_count?: number
        }
        Update: {
          code_hash?: string
          created_at?: string
          created_by?: string | null
          expires_at?: string | null
          id?: string
          max_uses?: number
          notes?: string | null
          revoked_at?: string | null
          used_count?: number
        }
        Relationships: [
          {
            foreignKeyName: "invite_codes_created_by_fkey"
            columns: ["created_by"]
            isOneToOne: false
            referencedRelation: "user_profiles"
            referencedColumns: ["id"]
          },
        ]
      }
      invite_redemption_attempts: {
        Row: {
          attempted_at: string
          email_hash: string
          id: number
          succeeded: boolean
        }
        Insert: {
          attempted_at?: string
          email_hash: string
          id?: never
          succeeded: boolean
        }
        Update: {
          attempted_at?: string
          email_hash?: string
          id?: never
          succeeded?: boolean
        }
        Relationships: []
      }
      invite_request_attempts: {
        Row: {
          attempted_at: string
          email_hash: string
          id: number
          succeeded: boolean
        }
        Insert: {
          attempted_at?: string
          email_hash: string
          id?: never
          succeeded: boolean
        }
        Update: {
          attempted_at?: string
          email_hash?: string
          id?: never
          succeeded?: boolean
        }
        Relationships: []
      }
      invite_requests: {
        Row: {
          admin_notes: string | null
          created_at: string
          email: string
          id: string
          invite_code_id: string | null
          message: string | null
          reviewed_at: string | null
          reviewed_by: string | null
          status: Database["public"]["Enums"]["invite_request_status"]
        }
        Insert: {
          admin_notes?: string | null
          created_at?: string
          email: string
          id?: string
          invite_code_id?: string | null
          message?: string | null
          reviewed_at?: string | null
          reviewed_by?: string | null
          status?: Database["public"]["Enums"]["invite_request_status"]
        }
        Update: {
          admin_notes?: string | null
          created_at?: string
          email?: string
          id?: string
          invite_code_id?: string | null
          message?: string | null
          reviewed_at?: string | null
          reviewed_by?: string | null
          status?: Database["public"]["Enums"]["invite_request_status"]
        }
        Relationships: [
          {
            foreignKeyName: "invite_requests_invite_code_id_fkey"
            columns: ["invite_code_id"]
            isOneToOne: false
            referencedRelation: "invite_codes"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "invite_requests_reviewed_by_fkey"
            columns: ["reviewed_by"]
            isOneToOne: false
            referencedRelation: "user_profiles"
            referencedColumns: ["id"]
          },
        ]
      }
      pending_invite_claims: {
        Row: {
          claimed_at: string | null
          claimed_by: string | null
          created_at: string
          email: string
          expires_at: string
          invite_code: string
        }
        Insert: {
          claimed_at?: string | null
          claimed_by?: string | null
          created_at?: string
          email: string
          expires_at?: string
          invite_code: string
        }
        Update: {
          claimed_at?: string | null
          claimed_by?: string | null
          created_at?: string
          email?: string
          expires_at?: string
          invite_code?: string
        }
        Relationships: [
          {
            foreignKeyName: "pending_invite_claims_claimed_by_fkey"
            columns: ["claimed_by"]
            isOneToOne: false
            referencedRelation: "user_profiles"
            referencedColumns: ["id"]
          },
        ]
      }
      ratings: {
        Row: {
          created_at: string
          event_id: string
          id: string
          score: number
          user_id: string
        }
        Insert: {
          created_at?: string
          event_id: string
          id?: string
          score: number
          user_id: string
        }
        Update: {
          created_at?: string
          event_id?: string
          id?: string
          score?: number
          user_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "ratings_event_id_fkey"
            columns: ["event_id"]
            isOneToOne: false
            referencedRelation: "events"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "ratings_event_id_fkey"
            columns: ["event_id"]
            isOneToOne: false
            referencedRelation: "public_events"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "ratings_user_id_fkey"
            columns: ["user_id"]
            isOneToOne: false
            referencedRelation: "user_profiles"
            referencedColumns: ["id"]
          },
        ]
      }
      recommendation_signals: {
        Row: {
          created_at: string
          event_id: string
          id: string
          signal_type: string
          user_id: string
          weight: number
        }
        Insert: {
          created_at?: string
          event_id: string
          id?: string
          signal_type: string
          user_id: string
          weight?: number
        }
        Update: {
          created_at?: string
          event_id?: string
          id?: string
          signal_type?: string
          user_id?: string
          weight?: number
        }
        Relationships: [
          {
            foreignKeyName: "recommendation_signals_event_id_fkey"
            columns: ["event_id"]
            isOneToOne: false
            referencedRelation: "events"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "recommendation_signals_event_id_fkey"
            columns: ["event_id"]
            isOneToOne: false
            referencedRelation: "public_events"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "recommendation_signals_user_id_fkey"
            columns: ["user_id"]
            isOneToOne: false
            referencedRelation: "user_profiles"
            referencedColumns: ["id"]
          },
        ]
      }
      source_extraction_traces: {
        Row: {
          created_at: string
          error: string | null
          extraction_mode: Database["public"]["Enums"]["source_extraction_mode"]
          extractor: string
          fallback_reason: string | null
          id: number
          input_bytes: number | null
          latency_ms: number | null
          model: string | null
          parsed_event_count: number
          provider: string | null
          reasoning_summary: string | null
          source_id: string | null
          source_queue_id: number | null
          source_run_id: string | null
          status: string
        }
        Insert: {
          created_at?: string
          error?: string | null
          extraction_mode: Database["public"]["Enums"]["source_extraction_mode"]
          extractor: string
          fallback_reason?: string | null
          id?: never
          input_bytes?: number | null
          latency_ms?: number | null
          model?: string | null
          parsed_event_count?: number
          provider?: string | null
          reasoning_summary?: string | null
          source_id?: string | null
          source_queue_id?: number | null
          source_run_id?: string | null
          status: string
        }
        Update: {
          created_at?: string
          error?: string | null
          extraction_mode?: Database["public"]["Enums"]["source_extraction_mode"]
          extractor?: string
          fallback_reason?: string | null
          id?: never
          input_bytes?: number | null
          latency_ms?: number | null
          model?: string | null
          parsed_event_count?: number
          provider?: string | null
          reasoning_summary?: string | null
          source_id?: string | null
          source_queue_id?: number | null
          source_run_id?: string | null
          status?: string
        }
        Relationships: [
          {
            foreignKeyName: "source_extraction_traces_source_id_fkey"
            columns: ["source_id"]
            isOneToOne: false
            referencedRelation: "event_sources"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "source_extraction_traces_source_queue_id_fkey"
            columns: ["source_queue_id"]
            isOneToOne: false
            referencedRelation: "source_scrape_queue"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "source_extraction_traces_source_run_id_fkey"
            columns: ["source_run_id"]
            isOneToOne: false
            referencedRelation: "source_runs"
            referencedColumns: ["id"]
          },
        ]
      }
      source_runs: {
        Row: {
          completed_at: string | null
          created_at: string
          error_log: string | null
          events_found: number
          events_imported: number
          events_skipped: number
          id: string
          source_id: string | null
          started_at: string
          status: string
        }
        Insert: {
          completed_at?: string | null
          created_at?: string
          error_log?: string | null
          events_found?: number
          events_imported?: number
          events_skipped?: number
          id?: string
          source_id?: string | null
          started_at?: string
          status?: string
        }
        Update: {
          completed_at?: string | null
          created_at?: string
          error_log?: string | null
          events_found?: number
          events_imported?: number
          events_skipped?: number
          id?: string
          source_id?: string | null
          started_at?: string
          status?: string
        }
        Relationships: [
          {
            foreignKeyName: "source_runs_source_id_fkey"
            columns: ["source_id"]
            isOneToOne: false
            referencedRelation: "event_sources"
            referencedColumns: ["id"]
          },
        ]
      }
      source_scrape_queue: {
        Row: {
          attempt_count: number
          enqueued_at: string
          finished_at: string | null
          id: number
          last_error: string | null
          next_attempt_at: string
          skip_reason: string | null
          source_id: string | null
          source_run_id: string | null
          started_at: string | null
          status: Database["public"]["Enums"]["source_scrape_queue_status"]
          trigger_type: string
        }
        Insert: {
          attempt_count?: number
          enqueued_at?: string
          finished_at?: string | null
          id?: never
          last_error?: string | null
          next_attempt_at?: string
          skip_reason?: string | null
          source_id?: string | null
          source_run_id?: string | null
          started_at?: string | null
          status?: Database["public"]["Enums"]["source_scrape_queue_status"]
          trigger_type?: string
        }
        Update: {
          attempt_count?: number
          enqueued_at?: string
          finished_at?: string | null
          id?: never
          last_error?: string | null
          next_attempt_at?: string
          skip_reason?: string | null
          source_id?: string | null
          source_run_id?: string | null
          started_at?: string | null
          status?: Database["public"]["Enums"]["source_scrape_queue_status"]
          trigger_type?: string
        }
        Relationships: [
          {
            foreignKeyName: "source_scrape_queue_source_id_fkey"
            columns: ["source_id"]
            isOneToOne: false
            referencedRelation: "event_sources"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "source_scrape_queue_source_run_id_fkey"
            columns: ["source_run_id"]
            isOneToOne: false
            referencedRelation: "source_runs"
            referencedColumns: ["id"]
          },
        ]
      }
      tags: {
        Row: {
          category: string
          color: string
          created_at: string
          id: string
          is_system: boolean
          name: string
          slug: string
        }
        Insert: {
          category?: string
          color?: string
          created_at?: string
          id?: string
          is_system?: boolean
          name: string
          slug: string
        }
        Update: {
          category?: string
          color?: string
          created_at?: string
          id?: string
          is_system?: boolean
          name?: string
          slug?: string
        }
        Relationships: []
      }
      user_access: {
        Row: {
          access_expires_at: string | null
          created_at: string
          disabled_at: string | null
          disabled_reason: string | null
          enabled_at: string | null
          is_enabled: boolean
          updated_at: string
          user_id: string
        }
        Insert: {
          access_expires_at?: string | null
          created_at?: string
          disabled_at?: string | null
          disabled_reason?: string | null
          enabled_at?: string | null
          is_enabled?: boolean
          updated_at?: string
          user_id: string
        }
        Update: {
          access_expires_at?: string | null
          created_at?: string
          disabled_at?: string | null
          disabled_reason?: string | null
          enabled_at?: string | null
          is_enabled?: boolean
          updated_at?: string
          user_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "user_access_user_id_fkey"
            columns: ["user_id"]
            isOneToOne: true
            referencedRelation: "user_profiles"
            referencedColumns: ["id"]
          },
        ]
      }
      user_calendar_events: {
        Row: {
          added_at: string
          event_id: string
          id: string
          notes: string | null
          user_id: string
        }
        Insert: {
          added_at?: string
          event_id: string
          id?: string
          notes?: string | null
          user_id: string
        }
        Update: {
          added_at?: string
          event_id?: string
          id?: string
          notes?: string | null
          user_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "user_calendar_events_event_id_fkey"
            columns: ["event_id"]
            isOneToOne: false
            referencedRelation: "events"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "user_calendar_events_event_id_fkey"
            columns: ["event_id"]
            isOneToOne: false
            referencedRelation: "public_events"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "user_calendar_events_user_id_fkey"
            columns: ["user_id"]
            isOneToOne: false
            referencedRelation: "user_profiles"
            referencedColumns: ["id"]
          },
        ]
      }
      user_profiles: {
        Row: {
          avatar_url: string | null
          child_age: number | null
          child_name: string | null
          city_preference_id: string | null
          created_at: string
          display_name: string | null
          email: string | null
          id: string
          role: string
          updated_at: string
        }
        Insert: {
          avatar_url?: string | null
          child_age?: number | null
          child_name?: string | null
          city_preference_id?: string | null
          created_at?: string
          display_name?: string | null
          email?: string | null
          id: string
          role?: string
          updated_at?: string
        }
        Update: {
          avatar_url?: string | null
          child_age?: number | null
          child_name?: string | null
          city_preference_id?: string | null
          created_at?: string
          display_name?: string | null
          email?: string | null
          id?: string
          role?: string
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "user_profiles_city_preference_id_fkey"
            columns: ["city_preference_id"]
            isOneToOne: false
            referencedRelation: "cities"
            referencedColumns: ["id"]
          },
        ]
      }
    }
    Views: {
      event_rating_stats: {
        Row: {
          avg_score: number | null
          event_id: string | null
          rating_count: number | null
        }
        Relationships: [
          {
            foreignKeyName: "ratings_event_id_fkey"
            columns: ["event_id"]
            isOneToOne: false
            referencedRelation: "events"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "ratings_event_id_fkey"
            columns: ["event_id"]
            isOneToOne: false
            referencedRelation: "public_events"
            referencedColumns: ["id"]
          },
        ]
      }
      event_tag_queue_summary: {
        Row: {
          avg_attempts: number | null
          last_dead_letter_at: string | null
          newest_enqueued_at: string | null
          oldest_enqueued_at: string | null
          row_count: number | null
          status: Database["public"]["Enums"]["event_tag_queue_status"] | null
        }
        Relationships: []
      }
      public_events: {
        Row: {
          address: string | null
          age_max: number | null
          age_min: number | null
          city_id: string | null
          description: string | null
          end_datetime: string | null
          id: string | null
          images: Json | null
          is_featured: boolean | null
          is_free: boolean | null
          latitude: number | null
          longitude: number | null
          price: number | null
          recurrence_info: Json | null
          source_name: string | null
          source_url: string | null
          start_datetime: string | null
          timezone: string | null
          title: string | null
          venue_name: string | null
        }
        Insert: {
          address?: string | null
          age_max?: number | null
          age_min?: number | null
          city_id?: string | null
          description?: string | null
          end_datetime?: string | null
          id?: string | null
          images?: Json | null
          is_featured?: boolean | null
          is_free?: boolean | null
          latitude?: number | null
          longitude?: number | null
          price?: number | null
          recurrence_info?: Json | null
          source_name?: string | null
          source_url?: string | null
          start_datetime?: string | null
          timezone?: string | null
          title?: string | null
          venue_name?: string | null
        }
        Update: {
          address?: string | null
          age_max?: number | null
          age_min?: number | null
          city_id?: string | null
          description?: string | null
          end_datetime?: string | null
          id?: string | null
          images?: Json | null
          is_featured?: boolean | null
          is_free?: boolean | null
          latitude?: number | null
          longitude?: number | null
          price?: number | null
          recurrence_info?: Json | null
          source_name?: string | null
          source_url?: string | null
          start_datetime?: string | null
          timezone?: string | null
          title?: string | null
          venue_name?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "events_city_id_fkey"
            columns: ["city_id"]
            isOneToOne: false
            referencedRelation: "cities"
            referencedColumns: ["id"]
          },
        ]
      }
      source_scrape_queue_summary: {
        Row: {
          avg_attempts: number | null
          last_dead_letter_at: string | null
          newest_finished_at: string | null
          oldest_enqueued_at: string | null
          oldest_processing_started_at: string | null
          row_count: number | null
          status:
            | Database["public"]["Enums"]["source_scrape_queue_status"]
            | null
        }
        Relationships: []
      }
      timezone_names: {
        Row: {
          name: string | null
        }
        Relationships: []
      }
    }
    Functions: {
      admin_approve_invite_request: {
        Args: { p_request_id: string }
        Returns: {
          code: string
          created_at: string
          email: string
          invite_code_id: string
          request_id: string
        }[]
      }
      admin_bulk_set_auto_approve: {
        Args: { enable: boolean }
        Returns: undefined
      }
      admin_create_event: {
        Args: { p_patch: Json; p_tag_ids?: string[] }
        Returns: {
          address: string | null
          admin_last_edited_at: string | null
          admin_last_edited_by: string | null
          admin_locked_fields: string[]
          age_max: number | null
          age_min: number | null
          ai_confidence: number | null
          ai_tag_model: string | null
          ai_tag_provider: string | null
          ai_tag_status: string | null
          city_id: string | null
          created_at: string
          description: string | null
          end_datetime: string | null
          id: string
          images: Json
          is_featured: boolean
          is_free: boolean
          is_outdoor: boolean | null
          latitude: number | null
          longitude: number | null
          price: number | null
          recurrence_info: Json | null
          search_vector: unknown
          source_id: string | null
          source_name: string | null
          source_url: string | null
          start_datetime: string
          status: string
          timezone: string
          title: string
          updated_at: string
          venue_name: string | null
          view_count: number
        }
        SetofOptions: {
          from: "*"
          to: "events"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      admin_create_invite_code: {
        Args: { p_expires_at?: string; p_max_uses?: number; p_notes?: string }
        Returns: {
          code: string
          created_at: string
          expires_at: string
          id: string
          max_uses: number
          notes: string
        }[]
      }
      admin_cron_run_history: {
        Args: { p_job_name?: string; p_limit?: number }
        Returns: {
          duration_ms: number
          end_time: string
          jobname: string
          return_message: string
          runid: number
          start_time: string
          status: string
        }[]
      }
      admin_delete_rating: { Args: { p_id: string }; Returns: boolean }
      admin_list_cron_jobs: {
        Args: never
        Returns: {
          active: boolean
          command: string
          jobid: number
          jobname: string
          last_run_end: string
          last_run_message: string
          last_run_start: string
          last_run_status: string
          schedule: string
        }[]
      }
      admin_list_railway_cron_jobs: {
        Args: never
        Returns: {
          enabled: boolean
          label: string
          last_http_status: number
          last_run_at: string
          last_run_duration_s: number
          last_run_status: string
        }[]
      }
      admin_railway_cron_run_history: {
        Args: { p_label?: string; p_limit?: number }
        Returns: {
          body: string
          duration_s: number
          http_status: number
          id: number
          label: string
          ran_at: string
          status: string
        }[]
      }
      admin_reject_invite_request: {
        Args: { p_notes?: string; p_request_id: string }
        Returns: boolean
      }
      admin_retry_source_scrape_queue: {
        Args: { p_queue_id: number }
        Returns: boolean
      }
      admin_retry_tag_queue: { Args: { p_event_id: string }; Returns: boolean }
      admin_revoke_invite_code: { Args: { p_id: string }; Returns: boolean }
      admin_run_due_scrapes: { Args: never; Returns: undefined }
      admin_set_cron_enabled: {
        Args: { p_enabled: boolean; p_label: string }
        Returns: undefined
      }
      admin_set_cron_schedule: {
        Args: { p_job_name: string; p_schedule: string }
        Returns: undefined
      }
      admin_toggle_cron_job: {
        Args: { p_active: boolean; p_job_name: string }
        Returns: undefined
      }
      admin_unlock_event_fields: {
        Args: { p_event_id: string }
        Returns: boolean
      }
      admin_update_event: {
        Args: {
          p_event_id: string
          p_lock_edited_fields?: boolean
          p_patch: Json
          p_tag_ids: string[]
        }
        Returns: {
          address: string | null
          admin_last_edited_at: string | null
          admin_last_edited_by: string | null
          admin_locked_fields: string[]
          age_max: number | null
          age_min: number | null
          ai_confidence: number | null
          ai_tag_model: string | null
          ai_tag_provider: string | null
          ai_tag_status: string | null
          city_id: string | null
          created_at: string
          description: string | null
          end_datetime: string | null
          id: string
          images: Json
          is_featured: boolean
          is_free: boolean
          is_outdoor: boolean | null
          latitude: number | null
          longitude: number | null
          price: number | null
          recurrence_info: Json | null
          search_vector: unknown
          source_id: string | null
          source_name: string | null
          source_url: string | null
          start_datetime: string
          status: string
          timezone: string
          title: string
          updated_at: string
          venue_name: string | null
          view_count: number
        }
        SetofOptions: {
          from: "*"
          to: "events"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      claim_pending_invite_access: { Args: never; Returns: boolean }
      claim_source_scrape_queue_batch: {
        Args: { p_limit?: number }
        Returns: {
          attempt_count: number
          enqueued_at: string
          finished_at: string | null
          id: number
          last_error: string | null
          next_attempt_at: string
          skip_reason: string | null
          source_id: string | null
          source_run_id: string | null
          started_at: string | null
          status: Database["public"]["Enums"]["source_scrape_queue_status"]
          trigger_type: string
        }[]
        SetofOptions: {
          from: "*"
          to: "source_scrape_queue"
          isOneToOne: false
          isSetofReturn: true
        }
      }
      claim_tag_queue_batch: {
        Args: { p_limit?: number }
        Returns: {
          attempt_count: number
          enqueued_at: string
          event_id: string
          finished_at: string | null
          id: number
          last_error: string | null
          next_attempt_at: string
          source_run_id: string | null
          started_at: string | null
          status: Database["public"]["Enums"]["event_tag_queue_status"]
          trigger_type: string
        }[]
        SetofOptions: {
          from: "*"
          to: "event_tag_queue"
          isOneToOne: false
          isSetofReturn: true
        }
      }
      delete_my_account: { Args: never; Returns: undefined }
      due_event_sources: {
        Args: { p_limit?: number }
        Returns: {
          auto_approve: boolean
          city_id: string | null
          created_at: string
          date_window_days: number | null
          error_count: number
          extraction_mode: Database["public"]["Enums"]["source_extraction_mode"]
          id: string
          is_active: boolean
          last_scraped_at: string | null
          last_status: string | null
          name: string
          notes: string | null
          scrape_interval_hours: number
          source_type: string
          updated_at: string
          url: string
        }[]
        SetofOptions: {
          from: "*"
          to: "event_sources"
          isOneToOne: false
          isSetofReturn: true
        }
      }
      events_enriched: {
        Args: {
          p_city_id?: string
          p_date_from?: string
          p_date_to?: string
          p_event_ids?: string[]
          p_limit?: number
          p_offset?: number
          p_status?: string
          p_user_id?: string
        }
        Returns: {
          address: string
          age_max: number
          age_min: number
          ai_confidence: number
          ai_tag_provider: string
          avg_rating: number
          city_id: string
          created_at: string
          description: string
          end_datetime: string
          id: string
          images: Json
          is_favorited: boolean
          is_featured: boolean
          is_free: boolean
          is_in_calendar: boolean
          latitude: number
          longitude: number
          price: number
          rating_count: number
          recurrence_info: Json
          search_vector: unknown
          source_id: string
          source_name: string
          source_url: string
          start_datetime: string
          status: string
          tags: Json
          timezone: string
          title: string
          updated_at: string
          venue_name: string
          view_count: number
        }[]
      }
      invites_required: { Args: never; Returns: boolean }
      invoke_process_tag_queue: { Args: never; Returns: undefined }
      invoke_scrape_source: {
        Args: { source_uuid: string }
        Returns: undefined
      }
      is_cron_enabled: { Args: { p_label: string }; Returns: boolean }
      is_enabled_user: { Args: never; Returns: boolean }
      log_railway_cron_run: {
        Args: {
          p_body?: string
          p_duration_s?: number
          p_http_status?: number
          p_label: string
          p_status: string
        }
        Returns: undefined
      }
      mark_source_scrape_queue_skipped: {
        Args: { p_queue_id: number; p_skip_reason: string }
        Returns: undefined
      }
      mark_source_scrape_queue_started: {
        Args: { p_queue_id: number }
        Returns: {
          attempt_count: number
          enqueued_at: string
          finished_at: string | null
          id: number
          last_error: string | null
          next_attempt_at: string
          skip_reason: string | null
          source_id: string | null
          source_run_id: string | null
          started_at: string | null
          status: Database["public"]["Enums"]["source_scrape_queue_status"]
          trigger_type: string
        }
        SetofOptions: {
          from: "*"
          to: "source_scrape_queue"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      mark_tag_queue_row_started: {
        Args: { p_queue_id: number }
        Returns: {
          attempt_count: number
          enqueued_at: string
          event_id: string
          finished_at: string | null
          id: number
          last_error: string | null
          next_attempt_at: string
          source_run_id: string | null
          started_at: string | null
          status: Database["public"]["Enums"]["event_tag_queue_status"]
          trigger_type: string
        }
        SetofOptions: {
          from: "*"
          to: "event_tag_queue"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      plan_events_first_nonempty_window: {
        Args: {
          p_city_id?: string
          p_date?: string
          p_kid_age?: number
          p_lat?: number
          p_limit?: number
          p_lng?: number
          p_max_days?: number
          p_user_id: string
          p_weather_fit?: string
        }
        Returns: {
          age_score: number
          day_offset: number
          distance_km: number
          distance_score: number
          event_id: string
          history_affinity: number
          score: number
          weather_score: number
        }[]
      }
      plan_events_for_user: {
        Args: {
          p_city_id?: string
          p_date?: string
          p_kid_age?: number
          p_lat?: number
          p_limit?: number
          p_lng?: number
          p_user_id: string
          p_weather_fit?: string
        }
        Returns: {
          age_score: number
          distance_km: number
          distance_score: number
          event_id: string
          history_affinity: number
          score: number
          weather_score: number
        }[]
      }
      reap_stuck_source_scrape_queue_rows: { Args: never; Returns: number }
      reap_stuck_tag_queue_rows: { Args: never; Returns: number }
      redeem_invite: { Args: { p_code: string }; Returns: boolean }
      redeem_invite_for_email: {
        Args: { p_code: string; p_email: string }
        Returns: boolean
      }
      release_unstarted_source_scrape_queue_rows: {
        Args: { p_claimed_ids: number[] }
        Returns: number
      }
      release_unstarted_tag_queue_rows: {
        Args: { p_claimed_ids: number[] }
        Returns: number
      }
      request_invite: {
        Args: { p_email: string; p_message?: string }
        Returns: boolean
      }
      run_cleanup_stale_runs: { Args: never; Returns: undefined }
      run_daily_maintenance: { Args: never; Returns: Json }
      run_due_source_scrapes: { Args: never; Returns: undefined }
      search_events: {
        Args: {
          p_age_max?: number
          p_age_min?: number
          p_city_id?: string
          p_date_from?: string
          p_date_to?: string
          p_is_featured?: boolean
          p_is_free?: boolean
          p_keyword?: string
          p_limit?: number
          p_offset?: number
          p_status?: string
          p_tag_slugs?: string[]
        }
        Returns: {
          address: string | null
          admin_last_edited_at: string | null
          admin_last_edited_by: string | null
          admin_locked_fields: string[]
          age_max: number | null
          age_min: number | null
          ai_confidence: number | null
          ai_tag_model: string | null
          ai_tag_provider: string | null
          ai_tag_status: string | null
          city_id: string | null
          created_at: string
          description: string | null
          end_datetime: string | null
          id: string
          images: Json
          is_featured: boolean
          is_free: boolean
          is_outdoor: boolean | null
          latitude: number | null
          longitude: number | null
          price: number | null
          recurrence_info: Json | null
          search_vector: unknown
          source_id: string | null
          source_name: string | null
          source_url: string | null
          start_datetime: string
          status: string
          timezone: string
          title: string
          updated_at: string
          venue_name: string | null
          view_count: number
        }[]
        SetofOptions: {
          from: "*"
          to: "events"
          isOneToOne: false
          isSetofReturn: true
        }
      }
      source_scrape_queue_schedule_retry: {
        Args: { p_attempt_count: number; p_error: string; p_queue_id: number }
        Returns: undefined
      }
    }
    Enums: {
      event_tag_queue_status:
        | "pending"
        | "processing"
        | "failed"
        | "dead"
        | "succeeded"
      invite_request_status: "pending" | "approved" | "rejected"
      source_extraction_mode: "deterministic" | "llm" | "deterministic_then_llm"
      source_scrape_queue_status:
        | "pending"
        | "processing"
        | "retrying"
        | "succeeded"
        | "dead"
    }
    CompositeTypes: {
      [_ in never]: never
    }
  }
}

type DatabaseWithoutInternals = Omit<Database, "__InternalSupabase">

type DefaultSchema = DatabaseWithoutInternals[Extract<keyof Database, "public">]

export type Tables<
  DefaultSchemaTableNameOrOptions extends
    | keyof (DefaultSchema["Tables"] & DefaultSchema["Views"])
    | { schema: keyof DatabaseWithoutInternals },
  TableName extends DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof (DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"] &
        DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Views"])
    : never = never,
> = DefaultSchemaTableNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? (DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"] &
      DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Views"])[TableName] extends {
      Row: infer R
    }
    ? R
    : never
  : DefaultSchemaTableNameOrOptions extends keyof (DefaultSchema["Tables"] &
        DefaultSchema["Views"])
    ? (DefaultSchema["Tables"] &
        DefaultSchema["Views"])[DefaultSchemaTableNameOrOptions] extends {
        Row: infer R
      }
      ? R
      : never
    : never

export type TablesInsert<
  DefaultSchemaTableNameOrOptions extends
    | keyof DefaultSchema["Tables"]
    | { schema: keyof DatabaseWithoutInternals },
  TableName extends DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"]
    : never = never,
> = DefaultSchemaTableNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"][TableName] extends {
      Insert: infer I
    }
    ? I
    : never
  : DefaultSchemaTableNameOrOptions extends keyof DefaultSchema["Tables"]
    ? DefaultSchema["Tables"][DefaultSchemaTableNameOrOptions] extends {
        Insert: infer I
      }
      ? I
      : never
    : never

export type TablesUpdate<
  DefaultSchemaTableNameOrOptions extends
    | keyof DefaultSchema["Tables"]
    | { schema: keyof DatabaseWithoutInternals },
  TableName extends DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"]
    : never = never,
> = DefaultSchemaTableNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"][TableName] extends {
      Update: infer U
    }
    ? U
    : never
  : DefaultSchemaTableNameOrOptions extends keyof DefaultSchema["Tables"]
    ? DefaultSchema["Tables"][DefaultSchemaTableNameOrOptions] extends {
        Update: infer U
      }
      ? U
      : never
    : never

export type Enums<
  DefaultSchemaEnumNameOrOptions extends
    | keyof DefaultSchema["Enums"]
    | { schema: keyof DatabaseWithoutInternals },
  EnumName extends DefaultSchemaEnumNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaEnumNameOrOptions["schema"]]["Enums"]
    : never = never,
> = DefaultSchemaEnumNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[DefaultSchemaEnumNameOrOptions["schema"]]["Enums"][EnumName]
  : DefaultSchemaEnumNameOrOptions extends keyof DefaultSchema["Enums"]
    ? DefaultSchema["Enums"][DefaultSchemaEnumNameOrOptions]
    : never

export type CompositeTypes<
  PublicCompositeTypeNameOrOptions extends
    | keyof DefaultSchema["CompositeTypes"]
    | { schema: keyof DatabaseWithoutInternals },
  CompositeTypeName extends PublicCompositeTypeNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[PublicCompositeTypeNameOrOptions["schema"]]["CompositeTypes"]
    : never = never,
> = PublicCompositeTypeNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[PublicCompositeTypeNameOrOptions["schema"]]["CompositeTypes"][CompositeTypeName]
  : PublicCompositeTypeNameOrOptions extends keyof DefaultSchema["CompositeTypes"]
    ? DefaultSchema["CompositeTypes"][PublicCompositeTypeNameOrOptions]
    : never

export const Constants = {
  public: {
    Enums: {
      event_tag_queue_status: [
        "pending",
        "processing",
        "failed",
        "dead",
        "succeeded",
      ],
      invite_request_status: ["pending", "approved", "rejected"],
      source_extraction_mode: [
        "deterministic",
        "llm",
        "deterministic_then_llm",
      ],
      source_scrape_queue_status: [
        "pending",
        "processing",
        "retrying",
        "succeeded",
        "dead",
      ],
    },
  },
} as const

