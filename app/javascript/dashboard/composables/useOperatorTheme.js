import { computed, onUnmounted, watch } from 'vue';
import { useAccount } from './useAccount';

export const operatorThemeForAccount = account =>
  account?.custom_attributes?.operator_theme === 'economyops'
    ? 'economyops'
    : 'neutral';

export function useOperatorTheme() {
  const { currentAccount } = useAccount();
  const theme = computed(() => operatorThemeForAccount(currentAccount.value));

  watch(
    theme,
    value => {
      if (typeof document !== 'undefined') {
        document.documentElement.dataset.operatorTheme = value;
      }
    },
    { immediate: true }
  );
  onUnmounted(() => {
    if (typeof document !== 'undefined') {
      delete document.documentElement.dataset.operatorTheme;
    }
  });

  return theme;
}
