import { createClient } from '@supabase/supabase-js';

const url = import.meta.env.VITE_SUPABASE_URL as string | undefined;
const key = import.meta.env.VITE_SUPABASE_ANON_KEY as string | undefined;
export const configured = Boolean(url && key && !url.includes('TU-PROYECTO') && !key.includes('TU_PUBLISHABLE'));
export const supabase = configured ? createClient(url!, key!, {
  auth: { persistSession: true, autoRefreshToken: true, detectSessionInUrl: true },
}) : null;

export type Condition = 'good' | 'regular' | 'bad' | 'out_of_service' | 'review';
export const conditionLabels: Record<Condition, string> = {
  good: 'Buen estado', regular: 'Regular', bad: 'Malo', out_of_service: 'Fuera de servicio', review: 'Pendiente de revisión',
};
