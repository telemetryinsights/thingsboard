/**
 * Copyright © 2016-2025 The Thingsboard Authors
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */
package org.thingsboard.server.common.data.plugin;

import java.io.Serializable;

/**
 * @author Andrew Shvayka
 */
public enum ComponentLifecycleEvent implements Serializable {
    // In sync with ComponentLifecycleEvent proto
    CREATED, STARTED, ACTIVATED, SUSPENDED, UPDATED, STOPPED, DELETED, FAILED, DEACTIVATED
}
