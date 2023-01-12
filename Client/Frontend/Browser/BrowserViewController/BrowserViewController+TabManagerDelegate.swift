// Copyright 2022 The Brave Authors. All rights reserved.
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/.

import Foundation
import WebKit
import SwiftUI
import Shared
import Data
import BraveShared
import BraveCore
import BraveUI
import BraveWallet
import os.log

extension BrowserViewController: TabManagerDelegate {
  func tabManager(_ tabManager: TabManager, didSelectedTabChange selected: Tab?, previous: Tab?) {
    // Remove the old accessibilityLabel. Since this webview shouldn't be visible, it doesn't need it
    // and having multiple views with the same label confuses tests.
    if let wv = previous?.webView {
      toolbarVisibilityViewModel.endScrollViewObservation(wv.scrollView)
      
      wv.endEditing(true)
      wv.accessibilityLabel = nil
      wv.accessibilityElementsHidden = true
      wv.accessibilityIdentifier = nil
      wv.removeFromSuperview()
    }

    toolbar?.setSearchButtonState(url: selected?.url)
    if let tab = selected, let webView = tab.webView {
      toolbarVisibilityViewModel.beginObservingScrollView(webView.scrollView)
      toolbarVisibilityCancellable = toolbarVisibilityViewModel.objectWillChange
        .receive(on: DispatchQueue.main)
        .sink(receiveValue: { [weak self] in
          guard let self = self else { return }
          let (state, progress) = (self.toolbarVisibilityViewModel.toolbarState,
                                   self.toolbarVisibilityViewModel.interactiveTransitionProgress)
          self.handleToolbarVisibilityStateChange(state, progress: progress)
        })
      
      updateURLBar()

      if let url = tab.url, !InternalURL.isValid(url: url) {
        let previousEstimatedProgress = previous?.webView?.estimatedProgress ?? 1.0
        let selectedEstimatedProgress = webView.estimatedProgress

        // Progress should be updated only if there's a difference between tabs.
        // Otherwise we do nothing, so switching between fully loaded tabs won't show the animation.
        if previousEstimatedProgress != selectedEstimatedProgress {
          topToolbar.updateProgressBar(Float(selectedEstimatedProgress))
        }
      } else {
        topToolbar.hideProgressBar()
      }

      readerModeCache = ReaderModeScriptHandler.cache(for: tab)
      ReaderModeHandler.readerModeCache = readerModeCache

      webViewContainer.addSubview(webView)
      webView.snp.remakeConstraints { make in
        make.left.right.top.bottom.equalTo(self.webViewContainer)
      }

      // This is a terrible workaround for a bad iOS 12 bug where PDF
      // content disappears any time the view controller changes (i.e.
      // the user taps on the tabs tray). It seems the only way to get
      // the PDF to redraw is to either reload it or revisit it from
      // back/forward list. To try and avoid hitting the network again
      // for the same PDF, we revisit the current back/forward item and
      // restore the previous scrollview zoom scale and content offset
      // after a short 100ms delay. *facepalm*
      //
      // https://bugzilla.mozilla.org/show_bug.cgi?id=1516524
      if tab.mimeType == MIMEType.PDF {
        let previousZoomScale = webView.scrollView.zoomScale
        let previousContentOffset = webView.scrollView.contentOffset

        if let currentItem = webView.backForwardList.currentItem {
          webView.go(to: currentItem)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(100)) {
          webView.scrollView.setZoomScale(previousZoomScale, animated: false)
          webView.scrollView.setContentOffset(previousContentOffset, animated: false)
        }
      }

      webView.accessibilityLabel = Strings.webContentAccessibilityLabel
      webView.accessibilityIdentifier = "contentView"
      webView.accessibilityElementsHidden = false

      if webView.url == nil {
        // The web view can go gray if it was zombified due to memory pressure.
        // When this happens, the URL is nil, so try restoring the page upon selection.
        tab.reload()
      }
    }

    updateToolbarUsingTabManager(tabManager)

    removeAllBars()
    if let bars = selected?.bars {
      for bar in bars {
        showBar(bar, animated: true)
      }
    }

    updateFindInPageVisibility(visible: false, tab: previous)
    displayPageZoom(visible: false)
    updateTabsBarVisibility()
    selected?.updatePullToRefreshVisibility()

    topToolbar.locationView.loading = selected?.loading ?? false
    navigationToolbar.updateBackStatus(selected?.canGoBack ?? false)
    navigationToolbar.updateForwardStatus(selected?.canGoForward ?? false)

    let shouldShowPlaylistURLBarButton = selected?.url?.isPlaylistSupportedSiteURL == true

    if let readerMode = selected?.getContentScript(name: ReaderModeScriptHandler.scriptName) as? ReaderModeScriptHandler,
      !shouldShowPlaylistURLBarButton {
      topToolbar.updateReaderModeState(readerMode.state)
      if readerMode.state == .active {
        showReaderModeBar(animated: false)
      } else {
        hideReaderModeBar(animated: false)
      }

      updatePlaylistURLBar(tab: selected, state: selected?.playlistItemState ?? .none, item: selected?.playlistItem)
    } else {
      topToolbar.updateReaderModeState(ReaderModeState.unavailable)
    }

    updateInContentHomePanel(selected?.url as URL?)

    notificationsPresenter.removeNotification(with: WalletNotification.Constant.id)
    WalletProviderPermissionRequestsManager.shared.cancelAllPendingRequests(for: [.eth, .sol])
    WalletProviderAccountCreationRequestManager.shared.cancelAllPendingRequests(coins: [.eth, .sol])
    updateURLBarWalletButton()
  }

  func tabManager(_ tabManager: TabManager, willAddTab tab: Tab) {
  }

  func tabManager(_ tabManager: TabManager, didAddTab tab: Tab) {
    // If we are restoring tabs then we update the count once at the end
    if !tabManager.isRestoring {
      updateToolbarUsingTabManager(tabManager)
    }
    tab.tabDelegate = self
    tab.walletKeyringService = BraveWallet.KeyringServiceFactory.get(privateMode: tab.isPrivate)
    updateTabsBarVisibility()
  }

  func tabManager(_ tabManager: TabManager, willRemoveTab tab: Tab) {
    tab.webView?.removeFromSuperview()
  }

  func tabManager(_ tabManager: TabManager, didRemoveTab tab: Tab) {
    updateToolbarUsingTabManager(tabManager)
    // tabDelegate is a weak ref (and the tab's webView may not be destroyed yet)
    // so we don't expcitly unset it.
    topToolbar.leaveOverlayMode(didCancel: true)
    updateTabsBarVisibility()

    if !PrivateBrowsingManager.shared.isPrivateBrowsing {
      rewards.reportTabClosed(tabId: Int(tab.rewardsId))
    }
  }

  func tabManagerDidAddTabs(_ tabManager: TabManager) {
    updateToolbarUsingTabManager(tabManager)
  }

  func tabManagerDidRestoreTabs(_ tabManager: TabManager) {
    updateToolbarUsingTabManager(tabManager)
  }

  func show(toast: Toast, afterWaiting delay: DispatchTimeInterval = SimpleToastUX.toastDelayBefore, duration: DispatchTimeInterval? = SimpleToastUX.toastDismissAfter) {
    if let downloadToast = toast as? DownloadToast {
      self.downloadToast = downloadToast
    }

    // If BVC isnt visible hold on to this toast until viewDidAppear
    if self.view.window == nil {
      self.pendingToast = toast
      return
    }

    toast.showToast(
      viewController: self, delay: delay, duration: duration,
      makeConstraints: { make in
        make.left.right.equalTo(self.view)
        make.bottom.equalTo(self.webViewContainer)
      })
  }

  func tabManagerDidRemoveAllTabs(_ tabManager: TabManager, toast: ButtonToast?) {
    guard let toast = toast, !PrivateBrowsingManager.shared.isPrivateBrowsing else {
      return
    }
    show(toast: toast, afterWaiting: ButtonToastUX.toastDelay)
  }

  func updateToolbarUsingTabManager(_ tabManager: TabManager) {
    // Update Tab Count on Tab-Tray Button
    let count = tabManager.tabsForCurrentMode.count
    toolbar?.updateTabCount(count)
    topToolbar.updateTabCount(count)

    // Update Actions for Tab-Tray Button
    var newTabMenuChildren: [UIAction] = []
    var addTabMenuChildren: [UIAction] = []

    if !PrivateBrowsingManager.shared.isPrivateBrowsing {
      let openNewPrivateTab = UIAction(
        title: Strings.newPrivateTabTitle,
        image: UIImage(systemName: "plus.square.fill.on.square.fill"),
        handler: UIAction.deferredActionHandler { [unowned self] _ in
          self.openBlankNewTab(attemptLocationFieldFocus: false, isPrivate: true)
        })

      if (UIDevice.current.userInterfaceIdiom == .pad && tabsBar.view.isHidden == true) || (UIDevice.current.userInterfaceIdiom == .phone && toolbar == nil) {
        newTabMenuChildren.append(openNewPrivateTab)
      }

      addTabMenuChildren.append(openNewPrivateTab)
    }

    let openNewTab = UIAction(
      title: PrivateBrowsingManager.shared.isPrivateBrowsing ? Strings.newPrivateTabTitle : Strings.newTabTitle,
      image: PrivateBrowsingManager.shared.isPrivateBrowsing ? UIImage(systemName: "plus.square.fill.on.square.fill") : UIImage(systemName: "plus.square.on.square"),
      handler: UIAction.deferredActionHandler { [unowned self] _ in
        self.openBlankNewTab(attemptLocationFieldFocus: false, isPrivate: PrivateBrowsingManager.shared.isPrivateBrowsing)
      })

    if (UIDevice.current.userInterfaceIdiom == .pad && tabsBar.view.isHidden) || (UIDevice.current.userInterfaceIdiom == .phone && toolbar == nil) {
      newTabMenuChildren.append(openNewTab)
    }
    addTabMenuChildren.append(openNewTab)

    var bookmarkMenuChildren: [UIAction] = []
    
    let containsWebPage = tabManager.selectedTab?.containsWebPage == true

    if tabManager.openedWebsitesCount > 0, containsWebPage {
      let bookmarkActiveTab = UIAction(
        title: Strings.addToMenuItem,
        image: UIImage(systemName: "book"),
        handler: UIAction.deferredActionHandler { [unowned self] _ in
          self.openAddBookmark()
        })

      bookmarkMenuChildren.append(bookmarkActiveTab)
    }
    
    if tabManager.tabsForCurrentMode.count > 1 {
      let bookmarkAllTabs = UIAction(
        title: String.localizedStringWithFormat(Strings.bookmarkAllTabsTitle, tabManager.tabsForCurrentMode.count),
        image: UIImage(systemName: "book"),
        handler: UIAction.deferredActionHandler { [unowned self] _ in
          let mode = BookmarkEditMode.addFolderUsingTabs(title: Strings.savedTabsFolderTitle, tabList: tabManager.tabsForCurrentMode)
          let addBookMarkController = AddEditBookmarkTableViewController(bookmarkManager: bookmarkManager, mode: mode)

          presentSettingsNavigation(with: addBookMarkController, cancelEnabled: true)
        })

      bookmarkMenuChildren.append(bookmarkAllTabs)
    }
    
    var duplicateTabMenuChildren: [UIAction] = []
    
    if containsWebPage, let selectedTab = tabManager.selectedTab, let url = selectedTab.fetchedURL {
      let duplicateActiveTab = UIAction(
        title: Strings.duplicateActiveTab,
        image: UIImage(systemName: "plus.square.on.square"),
        handler: UIAction.deferredActionHandler { [weak selectedTab] _ in
          guard let selectedTab = selectedTab else { return }
          
          tabManager.addTabAndSelect(
               URLRequest(url: url),
               afterTab: selectedTab,
               isPrivate: selectedTab.isPrivate
           )
        })

      duplicateTabMenuChildren.append(duplicateActiveTab)
    }
    
    var recentlyClosedMenuChildren: [UIAction] = []

    if !PrivateBrowsingManager.shared.isPrivateBrowsing {
      let recentlyClosedTab = UIAction(
        title: Strings.RecentlyClosed.viewRecentlyClosedTab,
        image: UIImage(braveSystemNamed: "brave.arrow.counterclockwise.rectangle"),
        handler: UIAction.deferredActionHandler { [weak self] _ in
          guard let self = self else { return }
          
          if PrivateBrowsingManager.shared.isPrivateBrowsing {
            return
          }
                  
          var recentlyClosedTabsView = RecentlyClosedTabsView(tabManager: tabManager)
          recentlyClosedTabsView.onRecentlyClosedSelected = { [weak self] recentlyClosed in
            self?.tabManager.addAndSelectRecentlyClosed(recentlyClosed)
          }
          
          self.present(UIHostingController(rootView: recentlyClosedTabsView), animated: true)
        })
      
      recentlyClosedMenuChildren.append(recentlyClosedTab)
    }
    
    var closeTabMenuChildren: [UIAction] = []

    let closeActiveTab = UIAction(
      title: String(format: Strings.closeTabTitle),
      image: UIImage(systemName: "xmark"),
      attributes: .destructive,
      handler: UIAction.deferredActionHandler { [unowned self] _ in
        if let tab = tabManager.selectedTab {
          if topToolbar.locationView.readerModeState == .active {
            hideReaderModeBar(animated: false)
          }
          
          // Add the tab information to recently closed before removing
          tabManager.addTabToRecentlyClosed(tab)
          tabManager.removeTab(tab)
        }
      })

    closeTabMenuChildren.append(closeActiveTab)

    if tabManager.tabsForCurrentMode.count > 1 {
      let closeAllTabs = UIAction(
        title: String(format: Strings.closeAllTabsTitle, tabManager.tabsForCurrentMode.count),
        image: UIImage(systemName: "xmark"),
        attributes: .destructive,
        handler: UIAction.deferredActionHandler { [unowned self] _ in

          let alert = UIAlertController(title: nil, message: Strings.closeAllTabsPrompt, preferredStyle: .actionSheet)
          let cancelAction = UIAlertAction(title: Strings.CancelString, style: .cancel)
          let closedTabsTitle = String(format: Strings.closeAllTabsTitle, tabManager.tabsForCurrentMode.count)
          let closeAllAction = UIAlertAction(title: closedTabsTitle, style: .destructive) { _ in
            if !PrivateBrowsingManager.shared.isPrivateBrowsing {
              // Add the tab information to recently closed before removing
              tabManager.addAllTabsToRecentlyClosed()
            }
            
            tabManager.removeAllForCurrentMode()
          }
          alert.addAction(closeAllAction)
          alert.addAction(cancelAction)

          if let popoverPresentation = alert.popoverPresentationController {
            let tabsButton = toolbar?.tabsButton ?? topToolbar.tabsButton
            popoverPresentation.sourceView = tabsButton
            popoverPresentation.sourceRect =
              .init(x: tabsButton.frame.width / 2, y: tabsButton.frame.height, width: 1, height: 1)
          }

          self.present(alert, animated: true)
        })

      closeTabMenuChildren.append(closeAllTabs)
    }

    let newTabMenu = UIMenu(title: "", options: .displayInline, children: newTabMenuChildren)
    let addTabMenu = UIMenu(title: "", options: .displayInline, children: addTabMenuChildren)
    let bookmarkMenu = UIMenu(title: "", options: .displayInline, children: bookmarkMenuChildren)
    let duplicateTabMenu = UIMenu(title: "", options: .displayInline, children: duplicateTabMenuChildren)
    let recentlyClosedMenu = UIMenu(title: "", options: .displayInline, children: recentlyClosedMenuChildren)
    let closeTabMenu = UIMenu(title: "", options: .displayInline, children: closeTabMenuChildren)
    
    let tabButtonMenuActionList = [closeTabMenu, recentlyClosedMenu, duplicateTabMenu, bookmarkMenu, newTabMenu]
    let addTabMenuActionList = [addTabMenu]

    toolbar?.tabsButton.menu = UIMenu(title: "", identifier: nil, children: tabButtonMenuActionList)
    toolbar?.searchButton.menu = UIMenu(title: "", identifier: nil, children: addTabMenuActionList)
    
    topToolbar.tabsButton.menu = UIMenu(title: "", identifier: nil, children: tabButtonMenuActionList)
    toolbar?.searchButton.menu = UIMenu(title: "", identifier: nil, children: addTabMenuActionList)
    
    // Update Actions for Add-Tab Button
    toolbar?.addTabButton.menu = UIMenu(title: "", identifier: nil, children: addTabMenuActionList)
  }
}