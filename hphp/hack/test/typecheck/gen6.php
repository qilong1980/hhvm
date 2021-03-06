<?hh // strict
/**
 * Copyright (c) 2014, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the "hack" directory of this source tree. An additional grant
 * of patent rights can be found in the PATENTS file in the same directory.
 *
 */

class A<T as A> {
  public function bar(T $x): T {
    return $x;
  }

}

class Z {

  public function foo(): void {}
}

function test(): void {
  $x = new A();
  $x->bar(new Z())->foo();
}

