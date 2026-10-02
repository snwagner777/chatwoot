import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { createConsumer } from '@rails/actioncable';
import AuthAPI from 'dashboard/api/auth';
import ActionCableConnector from '../actionCable';

vi.mock('@rails/actioncable', () => ({ createConsumer: vi.fn() }));
vi.mock('dashboard/api/auth', () => ({ default: { getAuthData: vi.fn() } }));
vi.mock('dashboard/composables/useImpersonation', () => ({
  useImpersonation: () => ({ isImpersonating: { value: false } }),
}));

describe('dashboard realtime session proof', () => {
  let createSubscription;
  const store = {
    getters: { getCurrentAccountId: 12, getCurrentUserID: 34 },
  };

  beforeEach(() => {
    vi.useFakeTimers();
    window.chatwootConfig = { websocketURL: 'wss://chat.example.test' };
    createSubscription = vi.fn(() => ({}));
    createConsumer.mockReturnValue({
      subscriptions: { create: createSubscription },
    });
  });

  afterEach(() => {
    vi.clearAllTimers();
    vi.useRealTimers();
  });

  it('passes matching auth credentials in the subscription frame without putting them in the URL', () => {
    AuthAPI.getAuthData.mockReturnValue({
      client: 'browser-client',
      'access-token': 'browser-token',
    });
    ActionCableConnector.init(store, 'pubsub-token');

    expect(createConsumer).toHaveBeenCalledExactlyOnceWith(
      'wss://chat.example.test/cable'
    );
    expect(createSubscription).toHaveBeenCalledWith(
      {
        channel: 'RoomChannel',
        pubsub_token: 'pubsub-token',
        account_id: 12,
        user_id: 34,
        client_id: 'browser-client',
        access_token: 'browser-token',
      },
      expect.any(Object)
    );
    expect(AuthAPI.getAuthData).toHaveBeenCalledTimes(1);
  });

  it('preserves native subscriptions when browser session credentials are unavailable', () => {
    AuthAPI.getAuthData.mockReturnValue(false);
    ActionCableConnector.init(store, 'pubsub-token');

    expect(createSubscription).toHaveBeenCalledWith(
      expect.objectContaining({
        channel: 'RoomChannel',
        client_id: null,
        access_token: null,
      }),
      expect.any(Object)
    );
  });
});
