// Copyright 2021 The Brave Authors. All rights reserved.
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/.

import XCTest
@testable import BraveWallet

class AddressTests: XCTestCase {
  func testAddressTruncation() {
    let address = "0xabcdef0123456789"
    XCTAssertEqual(address.truncatedAddress, "0xabcd…6789")

    let prefixlessAddress = "abcdef0123456789"
    XCTAssertEqual(prefixlessAddress.truncatedAddress, "abcd…6789")
  }

  func testRemovingHexPrefix() {
    let address = "0xabcdef0123456789"
    XCTAssertEqual(address.removingHexPrefix, "abcdef0123456789")

    let prefixlessAddress = "abcdef0123456789"
    XCTAssertEqual(prefixlessAddress.removingHexPrefix, "abcdef0123456789")
  }

  func testIsETHAddress() {
    let isAddressTrue = "0x0c84cD05f2Bc2AfD7f29d4E71346d17697C353b7"
    XCTAssertTrue(isAddressTrue.isETHAddress)

    let isAddressFalseNotHex = "0x0csadgasg"
    XCTAssertFalse(isAddressFalseNotHex.isETHAddress)

    let isAddressFalseWrongPrefix = "0c84cD05f2Bc2AfD7f29d4E71346d17697C353b7"
    XCTAssertFalse(isAddressFalseWrongPrefix.isETHAddress)

    let isAddressFalseTooShort = "0x84cD05f2"
    XCTAssertFalse(isAddressFalseTooShort.isETHAddress)

    let isAddressFalseNoHexDigits = "0x"
    XCTAssertFalse(isAddressFalseNoHexDigits.isETHAddress)
  }
  
  func testZwspOutput() {
    let address = "0x1bBE4E6EF7294c99358377abAd15A6d9E98127A2"
    let zwspAddress = "0\u{200b}x\u{200b}1\u{200b}b\u{200b}B\u{200b}E\u{200b}4\u{200b}E\u{200b}6\u{200b}E\u{200b}F\u{200b}7\u{200b}2\u{200b}9\u{200b}4\u{200b}c\u{200b}9\u{200b}9\u{200b}3\u{200b}5\u{200b}8\u{200b}3\u{200b}7\u{200b}7\u{200b}a\u{200b}b\u{200b}A\u{200b}d\u{200b}1\u{200b}5\u{200b}A\u{200b}6\u{200b}d\u{200b}9\u{200b}E\u{200b}9\u{200b}8\u{200b}1\u{200b}2\u{200b}7\u{200b}A\u{200b}2\u{200b}"
    let result = address.zwspOutput
    XCTAssertNotEqual(address, result)
    XCTAssertEqual(zwspAddress, result)
  }
}